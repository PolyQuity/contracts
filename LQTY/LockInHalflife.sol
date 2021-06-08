// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

import "../Dependencies/Ownable.sol";
import "../Dependencies/SafeMath.sol";

import "../Interfaces/IXHalfLife.sol";
import "../Interfaces/ILQTYToken.sol";

contract LockInHalflife is Ownable {

    using SafeMath for uint256;

    IXHalfLife public halflife;
    ILQTYToken public LQTY;

    // halflife = (halflifeK * secondsPerBlock) * (0.69 / (-ln(1 - halflifeRatio/1000)))
    uint256 public constant halflifeK = 23000;  // 2 second per block
    uint256 public constant halflifeRatio = 1;
    // halflife = (23000 * 2) * (0.69 / (-ln(1-0.001))) = 31724127.35 seconds = 367.17 days
    
    address public constant burnAddress = address(0x000000000000000000000000000000000000dEaD);

    address public teamHalflifeAdmin;

    mapping (address => uint256) public halflifeID;

    event LogCreateHalflife(address indexed receiver, uint256 amount, uint256 halflifeID);
    event LogDestroyHalflife(uint256 streamId);

    modifier onlyTeamHalflifeAdmin() {
        require(msg.sender == teamHalflifeAdmin, "LockInHalflife: not team halflife admin");
        _;
    }

    function setParams(
        address haillifeAddress,
        address lqtyAddress,
        address teamHalflifeAdminAddress,
        address[] memory receivers,
        uint256[] memory amounts,
        bool[] memory enableDestroy
    ) external onlyOwner {

        halflife = IXHalfLife(haillifeAddress);
        LQTY = ILQTYToken(lqtyAddress);
        teamHalflifeAdmin = teamHalflifeAdminAddress;

        require(receivers.length == amounts.length, "LockInHalflife: length not equal");
        require(receivers.length == enableDestroy.length, "LockInHalflife: length not equal");
        
        uint256 length = receivers.length;
        
        uint256 totalAmount;
        for (uint256 i = 0; i < length; i++){
            totalAmount = totalAmount.add(amounts[i]);
        }
        require(totalAmount == LQTY.balanceOf(address(this)), "LockInHalflife: amount not equal");
        
        LQTY.approve(address(halflife), totalAmount);

        for (uint256 i = 0; i < length; i++){
            _createHalflife(receivers[i], amounts[i], enableDestroy[i]);
        }

        _renounceOwnership();
    }

    function destroyHalflife (uint256 streamId) external onlyTeamHalflifeAdmin {
        
        halflife.cancelStream(streamId);
        LQTY.transfer(burnAddress, LQTY.balanceOf(address(this)));

        emit LogDestroyHalflife(streamId);
    }

    function _createHalflife(
        address receiver,
        uint256 amount,
        bool enableDestroy
    ) internal {        
        uint256 streamId = halflife.createStream(
            address(LQTY),
            receiver,
            amount,
            block.number + 1,
            halflifeK,
            halflifeRatio,
            enableDestroy
        );

        halflifeID[receiver] = streamId;

        emit LogCreateHalflife(receiver, amount, streamId);
    }
}