// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/LiquityMath.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Interfaces/ILQTYToken.sol";
import "./Dependencies/SafeERC20.sol";
import "./Interfaces/ILPTokenWrapper.sol";
import "./Interfaces/IUnipool.sol";
import "../Dependencies/console.sol";
import "../Dependencies/IUniswapV2Router.sol";


// Adapted from: https://github.com/Synthetixio/Unipool/blob/master/contracts/Unipool.sol
// Some more useful references:
// Synthetix proposal: https://sips.synthetix.io/sips/sip-31
// Original audit: https://github.com/sigp/public-audits/blob/master/synthetix/unipool/review.pdf
// Incremental changes (commit by commit) from the original to this version: https://github.com/liquity/dev/pull/271

// LPTokenWrapper contains the basic staking functionality
contract LPTokenWrapper is ILPTokenWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public uniToken;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual override {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        uniToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual override {
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        uniToken.safeTransfer(msg.sender, amount);
    }

    function stakeInternal(uint256 amount) internal {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
    }

    function withdrawInternal(uint256 amount) internal {
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
    }
}

/*
 * On deployment a new Uniswap pool will be created for the pair LUSD/ETH and its token will be set here.

 * Essentially the way it works is:

 * - Liquidity providers add funds to the Uniswap pool, and get UNIv2 LP tokens in exchange
 * - Liquidity providers stake those UNIv2 LP tokens into Unipool rewards contract
 * - Liquidity providers accrue rewards, proportional to the amount of staked tokens and staking time
 * - Liquidity providers can claim their rewards when they want
 * - Liquidity providers can unstake UNIv2 LP tokens to exit the program (i.e., stop earning rewards) when they want

 * Funds for rewards will only be added once, on deployment of LQTY token,
 * which will happen after this contract is deployed and before this `setParams` in this contract is called.

 * If at some point the total amount of staked tokens is zero, the clock will be “stopped”,
 * so the period will be extended by the time during which the staking pool is empty,
 * in order to avoid getting LQTY tokens locked.
 * That also means that the start time for the program will be the event that occurs first:
 * either LQTY token contract is deployed, and therefore LQTY tokens are minted to Unipool contract,
 * or first liquidity provider stakes UNIv2 LP tokens into it.
 */
contract LQTYUnipool is LPTokenWrapper, Ownable, CheckContract, IUnipool {
    using SafeERC20 for IERC20;

    string constant public NAME = "LQTYUnipool";

    uint256 public duration;
    ILQTYToken public lqtyToken;
    address public uniswapV2RouterAddress;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event LQTYTokenAddressChanged(address _lqtyTokenAddress);
    event UniTokenAddressChanged(address _uniTokenAddress);
    event UniswapV2RouterAddressChanged(address _uniswapV2RouterAddress);
    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'locked');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // initialization function
    function setParams(
        address _lqtyTokenAddress,
        address _uniTokenAddress,
        address _uniswapV2RouterAddress,
        uint _duration,
        uint _rewardAmount
    )
    external
    onlyOwner
    {
        checkContract(_lqtyTokenAddress);
        checkContract(_uniTokenAddress);
        checkContract(_uniswapV2RouterAddress);

        uniToken = IERC20(_uniTokenAddress);
        lqtyToken = ILQTYToken(_lqtyTokenAddress);
        uniswapV2RouterAddress = _uniswapV2RouterAddress;
        duration = _duration;

        _notifyRewardAmount(_rewardAmount, _duration);

        emit LQTYTokenAddressChanged(_lqtyTokenAddress);
        emit UniTokenAddressChanged(_uniTokenAddress);
        emit UniswapV2RouterAddressChanged(_uniswapV2RouterAddress);

        _renounceOwnership();
    }

    // Returns current timestamp if the rewards program has not finished yet, end time otherwise
    function lastTimeRewardApplicable() public view override returns (uint256) {
        return LiquityMath._min(block.timestamp, periodFinish);
    }

    // Returns the amount of rewards that correspond to each staked token
    function rewardPerToken() public view override returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable()
            .sub(lastUpdateTime)
            .mul(rewardRate)
            .mul(1e18)
            .div(totalSupply())
        );
    }

    // Returns the amount that an account can claim
    function earned(address account) public view override returns (uint256) {
        return
        balanceOf(account)
        .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
        .div(1e18)
        .add(rewards[account]);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount) public override {
        require(amount > 0, "Cannot stake 0");
        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        _updatePeriodFinish();
        _updateAccountReward(msg.sender);

        super.stake(amount);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override {
        require(amount > 0, "Cannot withdraw 0");
        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        _updateAccountReward(msg.sender);

        super.withdraw(amount);

        emit Withdrawn(msg.sender, amount);
    }

    // Shortcut to be able to unstake tokens and claim rewards in one transaction
    function withdrawAndClaim() external override {
        withdraw(balanceOf(msg.sender));
        claimReward();
    }

    function claimReward() public override {
        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        _updatePeriodFinish();
        _updateAccountReward(msg.sender);

        uint256 reward = earned(msg.sender);

        require(reward > 0, "Nothing to claim");

        rewards[msg.sender] = 0;
        lqtyToken.transfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    function addLiquidity(
        uint256 _lqtyAmount,
        uint256 _amountLqtyMin,
        uint256 _amountNativeTokenMin,
        address _to,
        uint256 _deadline
    ) public payable returns (uint amountLqty, uint amountNativeToken, uint liquidity) {
        IERC20 lqtyTokenCached = IERC20(address(lqtyToken));
        lqtyTokenCached.safeTransferFrom(msg.sender, address(this), _lqtyAmount);
        
        lqtyTokenCached.safeApprove(uniswapV2RouterAddress, 0);
        lqtyTokenCached.safeApprove(uniswapV2RouterAddress, _lqtyAmount);

        // add the liquidity
        return IUniswapV2Router02(uniswapV2RouterAddress).addLiquidityETH{value : msg.value}(
            address(lqtyToken),
            _lqtyAmount,
            _amountLqtyMin,
            _amountNativeTokenMin,
            _to,
            _deadline
        );
    }

    function removeLiquidity(
        uint256 _liquidity,
        uint256 _amountLqtyMin,
        uint256 _amountNativeTokenMin,
        address _to,
        uint256 _deadline
    ) external returns (uint amountToken, uint amountNativeToken) {

        require(_liquidity > 0, "Cannot remove 0");
        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        uniToken.safeTransferFrom(msg.sender, address(this), _liquidity);

        uniToken.safeApprove(uniswapV2RouterAddress, 0);
        uniToken.safeApprove(uniswapV2RouterAddress, _liquidity);

        // remove the liquidity
        return IUniswapV2Router02(uniswapV2RouterAddress).removeLiquidityETH(
            address(lqtyToken),
            _liquidity,
            _amountLqtyMin,
            _amountNativeTokenMin,
            _to,
            _deadline
        );
    }

    function addLiquidityAndStake(
        uint256 _lqtyAmount,
        uint256 _amountLqtyMin,
        uint256 _amountNativeTokenMin
    ) external payable lock {

        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        (uint amountLqty, uint amountNativeToken, uint liquidity) = addLiquidity(
            _lqtyAmount,
            _amountLqtyMin,
            _amountNativeTokenMin,
            address(this),
            now + 60
        );

        require(liquidity > 0, "Cannot stake 0");

        if (_lqtyAmount.sub(amountLqty) > 0) {
            IERC20(address(lqtyToken)).safeTransfer(msg.sender, _lqtyAmount.sub(amountLqty));
        }

        if (msg.value.sub(amountNativeToken) > 0) {
            payable(msg.sender).transfer(msg.value.sub(amountNativeToken));
        }

        _updatePeriodFinish();
        _updateAccountReward(msg.sender);

        stakeInternal(liquidity);
        emit Staked(msg.sender, liquidity);
    }

    function withdrawAndRemoveLiquidity(
        uint256 _amountToWithdraw,
        uint256 _amountLqtyMin,
        uint256 _amountNativeTokenMin
    ) external lock {
        require(_amountToWithdraw > 0, "Cannot withdraw 0");
        require(address(uniToken) != address(0), "Liquidity Pool Token has not been set yet");

        _updateAccountReward(msg.sender);
        withdrawInternal(_amountToWithdraw);
        emit Withdrawn(msg.sender, _amountToWithdraw);

        uniToken.safeApprove(uniswapV2RouterAddress, 0);
        uniToken.safeApprove(uniswapV2RouterAddress, _amountToWithdraw);

        // remove the liquidity
        IUniswapV2Router02(uniswapV2RouterAddress).removeLiquidityETH(
            address(lqtyToken),
            _amountToWithdraw,
            _amountLqtyMin,
            _amountNativeTokenMin,
            msg.sender,
            now + 60
        );
    }

    // Used only on initialization, sets the reward rate and the end time for the program
    function _notifyRewardAmount(uint256 _reward, uint256 _duration) internal {
        assert(_reward > 0);
        assert(_reward == lqtyToken.balanceOf(address(this)));
        assert(periodFinish == 0);

        _updateReward();

        rewardRate = _reward.div(_duration);

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(_duration);
        emit RewardAdded(_reward);
    }

    // Adjusts end time for the program after periods of zero total supply
    function _updatePeriodFinish() internal {
        if (totalSupply() == 0) {
            assert(periodFinish > 0);
            /*
             * If the finish period has been reached (but there are remaining rewards due to zero stake),
             * to get the new finish date we must add to the current timestamp the difference between
             * the original finish time and the last update, i.e.:
             *
             * periodFinish = block.timestamp.add(periodFinish.sub(lastUpdateTime));
             *
             * If we have not reached the end yet, we must extend it by adding to it the difference between
             * the current timestamp and the last update (the period where the supply has been empty), i.e.:
             *
             * periodFinish = periodFinish.add(block.timestamp.sub(lastUpdateTime));
             *
             * Both formulas are equivalent.
             */
            periodFinish = periodFinish.add(block.timestamp.sub(lastUpdateTime));
        }
    }

    function _updateReward() internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    function _updateAccountReward(address account) internal {
        _updateReward();

        assert(account != address(0));

        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}