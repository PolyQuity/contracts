// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IPriceFeed.sol";
import "./Dependencies/AggregatorV3Interface.sol";
import "./Dependencies/IBand.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/console.sol";

/*
* PriceFeed for mainnet deployment, to be connected to Chainlink's live ETH:USD aggregator reference 
* contract, and a wrapper contract TellorCaller, which connects to TellorMaster contract.
*
* The PriceFeed uses Chainlink as primary oracle, and Tellor as fallback. It contains logic for
* switching oracles based on oracle failures, timeouts, and conditions for returning to the primary
* Chainlink oracle.
*/
contract PriceFeed is Ownable, CheckContract, BaseMath, IPriceFeed {
    using SafeMath for uint256;

    string constant public NAME = "PriceFeed";

    AggregatorV3Interface public priceAggregator;  // Mainnet Chainlink aggregator
    IStdReference public bandCaller; // Mainnet band caller

    // Core Liquity contracts
    address borrowerOperationsAddress;
    address troveManagerAddress;

    uint constant public ETHUSD_TELLOR_REQ_ID = 1;

    // Use to convert a price answer to an 18-digit precision uint
    uint constant public TARGET_DIGITS = 18;
    uint constant public TELLOR_DIGITS = 6;

    // Maximum time period allowed since Chainlink's latest round data timestamp, beyond which Chainlink is considered frozen.
    uint constant public TIMEOUT = 14400;  // 4 hours: 60 * 60 * 4

    // Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
    uint constant public MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%

    /*
    * The maximum relative price difference between two oracle responses allowed in order for the PriceFeed
    * to return to using the Chainlink oracle. 18-digit precision.
    */
    uint constant public MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES = 5e16; // 5%

    // The last good price seen from an oracle by Liquity
    uint public lastGoodPrice;

    address public bandCallerAddressSetter;

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    uint constant public BAND_VALID_UPDATE_INTERVAL_FOR_FROZEN = 14400;  // 4 hours: 60 * 60 * 4
    uint constant public BAND_VALID_UPDATE_INTERVAL_FOR_BROKEN = 28800;  // 8 hours: 60 * 60 * 8

    enum Status {
        chainlinkWorking,
        //        usingTellorChainlinkUntrusted,
        usingBandChainlinkUntrusted,
        bothOraclesUntrusted,
        //        usingTellorChainlinkFrozen,
        usingBandChainlinkFrozen,
        //        usingChainlinkTellorUntrusted
        usingChainlinkBandUntrusted
    }

    // The current status of the PricFeed, which determines the conditions for the next price fetch attempt
    Status public status;

    event LastGoodPriceUpdated(uint _lastGoodPrice);
    event PriceFeedStatusChanged(Status newStatus);

    // --- Dependency setters ---

    function setAddresses(
        address _priceAggregatorAddress,
        address _bandCallerAddress
    )
    external
    onlyOwner
    {
        bandCallerAddressSetter = msg.sender;
        checkContract(_priceAggregatorAddress);
        checkContract(_bandCallerAddress);

        priceAggregator = AggregatorV3Interface(_priceAggregatorAddress);
        bandCaller = IStdReference(_bandCallerAddress);

        // Explicitly set initial system status
        status = Status.chainlinkWorking;

        // // Get an initial price from Chainlink to serve as first reference for lastGoodPrice
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse();
        ChainlinkResponse memory prevChainlinkResponse = _getPrevChainlinkResponse(chainlinkResponse.roundId, chainlinkResponse.decimals);

        require(!_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse) && !_chainlinkIsFrozen(chainlinkResponse),
            "PriceFeed: Chainlink must be working and current");

        _storeChainlinkPrice(chainlinkResponse);
        _renounceOwnership();
    }

    // --- Functions ---

    /*
    * fetchPrice():
    * Returns the latest price obtained from the Oracle. Called by Liquity functions that require a current price.
    *
    * Also callable by anyone externally.
    *
    * Non-view function - it stores the last good price seen by Liquity.
    *
    * Uses a main oracle (Chainlink) and a fallback oracle (Tellor) in case Chainlink fails. If both fail,
    * it uses the last good price seen by Liquity.
    *
    */
    function fetchPrice() external override returns (uint) {
        // Get current and previous price data from Chainlink, and current price data from Tellor
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse();
        ChainlinkResponse memory prevChainlinkResponse = _getPrevChainlinkResponse(chainlinkResponse.roundId, chainlinkResponse.decimals);
        IStdReference.ReferenceData memory bandResponse = _getCurrentBandResponse();

        // --- CASE 1: System fetched last price from Chainlink  ---
        if (status == Status.chainlinkWorking) {
            // If Chainlink is broken, try Band
            if (_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse)) {
                // If Band is broken then both oracles are untrusted, so return the last good price
                if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.bothOraclesUntrusted);
                    return lastGoodPrice;
                }
                /*
                * If Band is only frozen but otherwise returning valid data, return the last good price.
                * Band may need to be tipped to return current data.
                */
                if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.usingBandChainlinkUntrusted);
                    return lastGoodPrice;
                }

                // If Chainlink is broken and Band is working, switch to Band and return current Band price
                _changeStatus(Status.usingBandChainlinkUntrusted);
                return _storeBandPrice(bandResponse.rate);
            }

            // If Chainlink is frozen, try Band
            if (_chainlinkIsFrozen(chainlinkResponse)) {
                // If Band is broken too, remember Band broke, and return last good price
                if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.usingChainlinkBandUntrusted);
                    return lastGoodPrice;
                }

                // If Band is frozen or working, remember Chainlink froze, and switch to Band
                _changeStatus(Status.usingBandChainlinkFrozen);

                if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {return lastGoodPrice;}

                // If Band is working, use it
                return _storeBandPrice(bandResponse.rate);
            }

            // If Chainlink price has changed by > 50% between two consecutive rounds, compare it to Band's price
            if (_chainlinkPriceChangeAboveMax(chainlinkResponse, prevChainlinkResponse)) {
                // If Band is broken, both oracles are untrusted, and return last good price
                if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.bothOraclesUntrusted);
                    return lastGoodPrice;
                }

                // If Band is frozen, switch to Band and return last good price
                if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.usingBandChainlinkUntrusted);
                    return lastGoodPrice;
                }

                /*
                * If Band is live and both oracles have a similar price, conclude that Chainlink's large price deviation between
                * two consecutive rounds was likely a legitmate market price movement, and so continue using Chainlink
                */
                if (_bothOraclesSimilarPrice(chainlinkResponse, bandResponse.rate)) {
                    return _storeChainlinkPrice(chainlinkResponse);
                }

                // If Band is live but the oracles differ too much in price, conclude that Chainlink's initial price deviation was
                // an oracle failure. Switch to Band, and use Band price
                _changeStatus(Status.usingBandChainlinkUntrusted);
                return _storeBandPrice(bandResponse.rate);
            }

            // If Chainlink is working and Band is broken, remember Band is broken
            if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                _changeStatus(Status.usingChainlinkBandUntrusted);
            }

            // If Chainlink is working, return Chainlink current price (no status change)
            return _storeChainlinkPrice(chainlinkResponse);
        }


        // --- CASE 2: The system fetched last price from Band ---
        if (status == Status.usingBandChainlinkUntrusted) {
            // If both Band and Chainlink are live, unbroken, and reporting similar prices, switch back to Chainlink
            if (_bothOraclesLiveAndUnbrokenAndSimilarPrice(chainlinkResponse, prevChainlinkResponse, bandResponse)) {
                _changeStatus(Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse);
            }

            if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                _changeStatus(Status.bothOraclesUntrusted);
                return lastGoodPrice;
            }

            /*
            * If Band is only frozen but otherwise returning valid data, just return the last good price.
            * Band may need to be tipped to return current data.
            */
            if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {return lastGoodPrice;}

            // Otherwise, use Band price
            return _storeBandPrice(bandResponse.rate);
        }

        // --- CASE 3: Both oracles were untrusted at the last price fetch ---
        if (status == Status.bothOraclesUntrusted) {
            /*
            * If both oracles are now live, unbroken and similar price, we assume that they are reporting
            * accurately, and so we switch back to Chainlink.
            */
            if (_bothOraclesLiveAndUnbrokenAndSimilarPrice(chainlinkResponse, prevChainlinkResponse, bandResponse)) {
                _changeStatus(Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse);
            }

            // Otherwise, return the last good price - both oracles are still untrusted (no status change)
            return lastGoodPrice;
        }

        // --- CASE 4: Using Band, and Chainlink is frozen ---
        if (status == Status.usingBandChainlinkFrozen) {
            if (_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse)) {
                // If both Oracles are broken, return last good price
                if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.bothOraclesUntrusted);
                    return lastGoodPrice;
                }

                // If Chainlink is broken, remember it and switch to using Band
                _changeStatus(Status.usingBandChainlinkUntrusted);

                if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {return lastGoodPrice;}

                // If Band is working, return Band current price
                return _storeBandPrice(bandResponse.rate);
            }

            if (_chainlinkIsFrozen(chainlinkResponse)) {
                // if Chainlink is frozen and Band is broken, remember Band broke, and return last good price
                if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                    _changeStatus(Status.usingChainlinkBandUntrusted);
                    return lastGoodPrice;
                }

                // If both are frozen, just use lastGoodPrice
                if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {return lastGoodPrice;}

                // if Chainlink is frozen and Band is working, keep using Band (no status change)
                return _storeBandPrice(bandResponse.rate);
            }

            // if Chainlink is live and Band is broken, remember Band broke, and return Chainlink price
            if (_bandIsBroken(bandResponse.lastUpdatedBase)) {
                _changeStatus(Status.usingChainlinkBandUntrusted);
                return _storeChainlinkPrice(chainlinkResponse);
            }

            // If Chainlink is live and Band is frozen, just use last good price (no status change) since we have no basis for comparison
            if (_bandIsFrozen(bandResponse.lastUpdatedBase)) {return lastGoodPrice;}

            // If Chainlink is live and Band is working, compare prices. Switch to Chainlink
            // if prices are within 5%, and return Chainlink price.
            if (_bothOraclesSimilarPrice(chainlinkResponse, bandResponse.rate)) {
                _changeStatus(Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse);
            }

            // Otherwise if Chainlink is live but price not within 5% of Band, distrust Chainlink, and return Band price
            _changeStatus(Status.usingBandChainlinkUntrusted);
            return _storeBandPrice(bandResponse.rate);
        }

        // --- CASE 5: Using Chainlink, Band is untrusted ---
        if (status == Status.usingChainlinkBandUntrusted) {
            // If Chainlink breaks, now both oracles are untrusted
            if (_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(Status.bothOraclesUntrusted);
                return lastGoodPrice;
            }

            // If Chainlink is frozen, return last good price (no status change)
            if (_chainlinkIsFrozen(chainlinkResponse)) {
                return lastGoodPrice;
            }

            // If Chainlink and Band are both live, unbroken and similar price, switch back to chainlinkWorking and return Chainlink price
            if (_bothOraclesLiveAndUnbrokenAndSimilarPrice(chainlinkResponse, prevChainlinkResponse, bandResponse)) {
                _changeStatus(Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse);
            }

            // If Chainlink is live but deviated >50% from it's previous price and Band is still untrusted, switch
            // to bothOraclesUntrusted and return last good price
            if (_chainlinkPriceChangeAboveMax(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(Status.bothOraclesUntrusted);
                return lastGoodPrice;
            }

            // Otherwise if Chainlink is live and deviated <50% from it's previous price and Band is still untrusted,
            // return Chainlink price (no status change)
            return _storeChainlinkPrice(chainlinkResponse);
        }
    }

    // --- Helper functions ---

    /* Chainlink is considered broken if its current or previous round data is in any way bad. We check the previous round
    * for two reasons:
    *
    * 1) It is necessary data for the price deviation check in case 1,
    * and
    * 2) Chainlink is the PriceFeed's preferred primary oracle - having two consecutive valid round responses adds
    * peace of mind when using or returning to Chainlink.
    */
    function _chainlinkIsBroken(ChainlinkResponse memory _currentResponse, ChainlinkResponse memory _prevResponse) internal view returns (bool) {
        return _badChainlinkResponse(_currentResponse) || _badChainlinkResponse(_prevResponse);
    }

    function _badChainlinkResponse(ChainlinkResponse memory _response) internal view returns (bool) {
        // Check for response call reverted
        if (!_response.success) {return true;}
        // Check for an invalid roundId that is 0
        if (_response.roundId == 0) {return true;}
        // Check for an invalid timeStamp that is 0, or in the future
        if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {return true;}
        // Check for non-positive price
        if (_response.answer <= 0) {return true;}

        return false;
    }

    function _chainlinkIsFrozen(ChainlinkResponse memory _response) internal view returns (bool) {
        return block.timestamp.sub(_response.timestamp) > TIMEOUT;
    }

    function _chainlinkPriceChangeAboveMax(ChainlinkResponse memory _currentResponse, ChainlinkResponse memory _prevResponse) internal pure returns (bool) {
        uint currentScaledPrice = _scaleChainlinkPriceByDigits(uint256(_currentResponse.answer), _currentResponse.decimals);
        uint prevScaledPrice = _scaleChainlinkPriceByDigits(uint256(_prevResponse.answer), _prevResponse.decimals);

        uint minPrice = LiquityMath._min(currentScaledPrice, prevScaledPrice);
        uint maxPrice = LiquityMath._max(currentScaledPrice, prevScaledPrice);

        /*
        * Use the larger price as the denominator:
        * - If price decreased, the percentage deviation is in relation to the the previous price.
        * - If price increased, the percentage deviation is in relation to the current price.
        */
        uint percentDeviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);

        // Return true if price has more than doubled, or more than halved.
        return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
    }

    function _bandIsBroken(uint256 _bandLastUpdatedBase) internal view returns (bool) {
        // check base updated time(FTM)
        return block.timestamp.sub(_bandLastUpdatedBase) > BAND_VALID_UPDATE_INTERVAL_FOR_BROKEN;
    }

    function _bandIsFrozen(uint256 _bandLastUpdatedBase) internal view returns (bool) {
        return block.timestamp.sub(_bandLastUpdatedBase) > BAND_VALID_UPDATE_INTERVAL_FOR_FROZEN;
    }

    //    function _tellorIsBroken(TellorResponse memory _response) internal view returns (bool) {
    //        // Check for response call reverted
    //        if (!_response.success) {return true;}
    //        // Check for an invalid timeStamp that is 0, or in the future
    //        if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {return true;}
    //        // Check for zero price
    //        if (_response.value == 0) {return true;}
    //
    //        return false;
    //    }

    //    function _tellorIsFrozen(TellorResponse  memory _tellorResponse) internal view returns (bool) {
    //        return block.timestamp.sub(_tellorResponse.timestamp) > TIMEOUT;
    //    }

    //    function _bothOraclesLiveAndUnbrokenAndSimilarPrice
    //    (
    //        ChainlinkResponse memory _chainlinkResponse,
    //        ChainlinkResponse memory _prevChainlinkResponse,
    //        TellorResponse memory _tellorResponse
    //    )
    //    internal
    //    view
    //    returns (bool)
    //    {
    //        // Return false if either oracle is broken or frozen
    //        if
    //        (
    //            _tellorIsBroken(_tellorResponse) ||
    //            _tellorIsFrozen(_tellorResponse) ||
    //            _chainlinkIsBroken(_chainlinkResponse, _prevChainlinkResponse) ||
    //            _chainlinkIsFrozen(_chainlinkResponse)
    //        )
    //        {
    //            return false;
    //        }
    //
    //        return _bothOraclesSimilarPrice(_chainlinkResponse, _tellorResponse);
    //    }
    function _bothOraclesLiveAndUnbrokenAndSimilarPrice
    (
        ChainlinkResponse memory _chainlinkResponse,
        ChainlinkResponse memory _prevChainlinkResponse,
        IStdReference.ReferenceData memory _bandResponse
    )
    internal
    view
    returns (bool)
    {
        // Return false if either oracle is broken or frozen
        if
        (
            _bandIsBroken(_bandResponse.lastUpdatedBase) ||
            _bandIsFrozen(_bandResponse.lastUpdatedBase) ||
            _chainlinkIsBroken(_chainlinkResponse, _prevChainlinkResponse) ||
            _chainlinkIsFrozen(_chainlinkResponse)
        )
        {
            return false;
        }

        return _bothOraclesSimilarPrice(_chainlinkResponse, _bandResponse.rate);
    }

    //    function _bothOraclesSimilarPrice(ChainlinkResponse memory _chainlinkResponse, TellorResponse memory _tellorResponse) internal pure returns (bool) {
    //        uint scaledChainlinkPrice = _scaleChainlinkPriceByDigits(uint256(_chainlinkResponse.answer), _chainlinkResponse.decimals);
    //        uint scaledTellorPrice = _scaleTellorPriceByDigits(_tellorResponse.value);
    //
    //        // Get the relative price difference between the oracles. Use the lower price as the denominator, i.e. the reference for the calculation.
    //        uint minPrice = LiquityMath._min(scaledTellorPrice, scaledChainlinkPrice);
    //        uint maxPrice = LiquityMath._max(scaledTellorPrice, scaledChainlinkPrice);
    //        uint percentPriceDifference = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(minPrice);
    //
    //        /*
    //        * Return true if the relative price difference is <= 3%: if so, we assume both oracles are probably reporting
    //        * the honest market price, as it is unlikely that both have been broken/hacked and are still in-sync.
    //        */
    //        return percentPriceDifference <= MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES;
    //    }
    function _bothOraclesSimilarPrice(ChainlinkResponse memory _chainlinkResponse, uint256 _bandPrice) internal pure returns (bool) {
        uint scaledChainlinkPrice = _scaleChainlinkPriceByDigits(uint256(_chainlinkResponse.answer), _chainlinkResponse.decimals);

        // Get the relative price difference between the oracles. Use the lower price as the denominator, i.e. the reference for the calculation.
        uint minPrice = LiquityMath._min(_bandPrice, scaledChainlinkPrice);
        uint maxPrice = LiquityMath._max(_bandPrice, scaledChainlinkPrice);
        uint percentPriceDifference = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(minPrice);

        /*
        * Return true if the relative price difference is <= 3%: if so, we assume both oracles are probably reporting
        * the honest market price, as it is unlikely that both have been broken/hacked and are still in-sync.
        */
        return percentPriceDifference <= MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES;
    }

    function _scaleChainlinkPriceByDigits(uint _price, uint _answerDigits) internal pure returns (uint) {
        /*
        * Convert the price returned by the Chainlink oracle to an 18-digit decimal for use by Liquity.
        * At date of Liquity launch, Chainlink uses an 8-digit price, but we also handle the possibility of
        * future changes.
        *
        */
        uint price;
        if (_answerDigits >= TARGET_DIGITS) {
            // Scale the returned price value down to Liquity's target precision
            price = _price.div(10 ** (_answerDigits - TARGET_DIGITS));
        }
        else if (_answerDigits < TARGET_DIGITS) {
            // Scale the returned price value up to Liquity's target precision
            price = _price.mul(10 ** (TARGET_DIGITS - _answerDigits));
        }
        return price;
    }

    function _scaleTellorPriceByDigits(uint _price) internal pure returns (uint) {
        return _price.mul(10 ** (TARGET_DIGITS - TELLOR_DIGITS));
    }

    function _changeStatus(Status _status) internal {
        status = _status;
        emit PriceFeedStatusChanged(_status);
    }

    function _storePrice(uint _currentPrice) internal {
        lastGoodPrice = _currentPrice;
        emit LastGoodPriceUpdated(_currentPrice);
    }

    //    function _storeTellorPrice(TellorResponse memory _tellorResponse) internal returns (uint) {
    //        uint scaledTellorPrice = _scaleTellorPriceByDigits(_tellorResponse.value);
    //        _storePrice(scaledTellorPrice);
    //
    //        return scaledTellorPrice;
    //    }

    function _storeBandPrice(uint256 _bandPrice) internal returns (uint) {
        // price in band response has 18 decimals
        _storePrice(_bandPrice);

        return _bandPrice;
    }

    function _storeChainlinkPrice(ChainlinkResponse memory _chainlinkResponse) internal returns (uint) {
        uint scaledChainlinkPrice = _scaleChainlinkPriceByDigits(uint256(_chainlinkResponse.answer), _chainlinkResponse.decimals);
        _storePrice(scaledChainlinkPrice);

        return scaledChainlinkPrice;
    }

    // --- Oracle response wrapper functions ---

    //    function _getCurrentTellorResponse() internal view returns (TellorResponse memory tellorResponse) {
    //        try tellorCaller.getTellorCurrentValue(ETHUSD_TELLOR_REQ_ID) returns
    //        (
    //            bool ifRetrieve,
    //            uint256 value,
    //            uint256 _timestampRetrieved
    //        )
    //        {
    //            // If call to Tellor succeeds, return the response and success = true
    //            tellorResponse.ifRetrieve = ifRetrieve;
    //            tellorResponse.value = value;
    //            tellorResponse.timestamp = _timestampRetrieved;
    //            tellorResponse.success = true;
    //
    //            return (tellorResponse);
    //        }catch {
    //            // If call to Tellor reverts, return a zero response with success = false
    //            return (tellorResponse);
    //        }
    //    }

    function _getCurrentBandResponse() internal view returns (IStdReference.ReferenceData memory bandResponse){
        return bandCaller.getReferenceData("MATIC", "USD");
    }

    function _getCurrentChainlinkResponse() internal view returns (ChainlinkResponse memory chainlinkResponse) {
        // First, try to get current decimal precision:
        try priceAggregator.decimals() returns (uint8 decimals) {
            // If call to Chainlink succeeds, record the current decimal precision
            chainlinkResponse.decimals = decimals;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }

        // Secondly, try to get latest price data:
        try priceAggregator.latestRoundData() returns
        (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = timestamp;
            chainlinkResponse.success = true;
            return chainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }
    }

    function _getPrevChainlinkResponse(uint80 _currentRoundId, uint8 _currentDecimals) internal view returns (ChainlinkResponse memory prevChainlinkResponse) {
        /*
        * NOTE: Chainlink only offers a current decimals() value - there is no way to obtain the decimal precision used in a
        * previous round.  We assume the decimals used in the previous round are the same as the current round.
        */

        // Try to get the price data from the previous round:
        try priceAggregator.getRoundData(_currentRoundId - 1) returns
        (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
            // If call to Chainlink succeeds, return the response and success = true
            prevChainlinkResponse.roundId = roundId;
            prevChainlinkResponse.answer = answer;
            prevChainlinkResponse.timestamp = timestamp;
            prevChainlinkResponse.decimals = _currentDecimals;
            prevChainlinkResponse.success = true;
            return prevChainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return prevChainlinkResponse;
        }
    }

    function setBandCallerAddress(address _bandCallerAddress) external {
        require(bandCallerAddressSetter == msg.sender, "PriceFeed: Invalid identity");
        checkContract(_bandCallerAddress);
        bandCaller = IStdReference(_bandCallerAddress);

        // Get an initial price from Band and check its validity
        IStdReference.ReferenceData memory bandResponse = _getCurrentBandResponse();
        // 1.check band's timeliness
        require(!_bandIsBroken(bandResponse.lastUpdatedBase) && !_bandIsFrozen(bandResponse.lastUpdatedBase),
            "PriceFeed: Band must be working and current");
        // 2.check the correctness of bandResponse's price
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse();
        require(_bothOraclesSimilarPrice(chainlinkResponse, bandResponse.rate),
            "PriceFeed: Band's price doesn't meet expectations");

        // renounce bandCallerAddressSetter
        bandCallerAddressSetter = address(0);
    }
}

