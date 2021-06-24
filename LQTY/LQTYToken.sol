// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Interfaces/ILockupContractFactory.sol";
import "../Dependencies/console.sol";
import "../Dependencies/IUniswapV2Router.sol";
import "../Interfaces/IUniswapFactory.sol";

/*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*  
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
* 
*
*  --- Functionality added specific to the LQTYToken ---
* 
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external 
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending LQTY directly to a Liquity
* core contract, when they should rather call the right function.
*
* 2) sendToLQTYStaking(): callable only by Liquity core contracts, which move LQTY tokens from user -> LQTYStaking contract.
*
* 3) Supply hard-capped at 100 million
*
* 4) CommunityIssuance and LockupContractFactory addresses are set at deployment
*
* 5) The bug bounties / hackathons allocation of 2 million tokens is minted at deployment to an EOA

* 6) 32 million tokens are minted at deployment to the CommunityIssuance contract
*
* 7) The LP rewards allocation of (1 + 1/3) million tokens is minted at deployent to a Staking contract
*
* 8) (64 + 2/3) million tokens are minted at deployment to the Liquity multisig
*
* 9) Until one year from deployment:
* -Liquity multisig may only transfer() tokens to LockupContracts that have been deployed via & registered in the 
*  LockupContractFactory 
* -approve(), increaseAllowance(), decreaseAllowance() revert when called by the multisig
* -transferFrom() reverts when the multisig is the sender
* -sendToLQTYStaking() reverts when the multisig is the sender, blocking the multisig from staking its LQTY.
* 
* After one year has passed since deployment of the LQTYToken, the restrictions on multisig operations are lifted
* and the multisig has the same rights as any other address.
*/

contract LQTYToken is CheckContract, ILQTYToken, Ownable {
    using SafeMath for uint256;

    struct TransferFee {
        uint256 threshold;
        uint256 stakingFee;
        uint256 deflationFee;
    }

    struct InitialAllocation {
        address communityIssuanceAddress;
        address LQTYlpRewardsAddress;
        address LUSDlpRewardsAddress;
        
        address multisigAddressForPUSDReward;
        address multisigAddressForTopDeFi;
        address multisigAddressForLiquidity;
        
        address lockInHalflifeAddress;
    }

    // --- ERC20 Data ---
    string constant internal _NAME = "PYQ";
    string constant internal _SYMBOL = "PYQ";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    mapping(address => uint256) private _nonces;

    // --- LQTYToken specific data ---

    // uint for use with SafeMath
    uint internal _10_MILLION = 10 * 1e24;
    uint internal immutable deploymentStartTime;

    address public immutable communityIssuanceAddress;
    address public immutable lqtyStakingAddress;
    address public immutable uniswapV2RouterAddress;
    address public immutable uniswapV2PairAddress;
    
    // address public immutable multisigAddressForStableCoinDex;
    // address public immutable multisigAddressForLQTYHolders;
    // address public immutable multisigAddressForPartners;
    
    InitialAllocation public initialAllocationAddresses;
    
    // transfer fee
    TransferFee private transferFeeStage1 = TransferFee(997 * 1e24, 10, 15);
    TransferFee private transferFeeStage2 = TransferFee(700 * 1e24, 4,  1);
    TransferFee private transferFeeStage3 = TransferFee(0, 1, 0);
    uint private constant transferFeeDenominator = 100;

    mapping(address => bool) public _isExcludedFromFee;

    // --- Events ---
    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event LQTYStakingAddressSet(address _lqtyStakingAddress);
    event MultiSigAddressSet(address _multisigAddressForPUSDReward, address _multisigAddressForTopDeFi, address _multisigAddressForLiquidity);
    // --- Functions ---

    constructor
    (
        address _lqtyStakingAddress,
        address _uniswapV2RouterAddress,
        address _liquidityTokenAddress,
        InitialAllocation memory _initialAllocationAddresses
    )
    public
    {
        // --- Set Address ---

        checkContract(_lqtyStakingAddress);
        checkContract(_uniswapV2RouterAddress);
        checkContract(_liquidityTokenAddress);

        checkContract(_initialAllocationAddresses.communityIssuanceAddress);

        checkContract(_initialAllocationAddresses.LQTYlpRewardsAddress);
        checkContract(_initialAllocationAddresses.LUSDlpRewardsAddress);
        checkContract(_initialAllocationAddresses.lockInHalflifeAddress);

        checkContract(_initialAllocationAddresses.multisigAddressForPUSDReward);
        checkContract(_initialAllocationAddresses.multisigAddressForTopDeFi);
        checkContract(_initialAllocationAddresses.multisigAddressForLiquidity);

        deploymentStartTime = block.timestamp;

        initialAllocationAddresses = _initialAllocationAddresses;
        
        lqtyStakingAddress = _lqtyStakingAddress;
        communityIssuanceAddress = _initialAllocationAddresses.communityIssuanceAddress;

        uniswapV2RouterAddress = _uniswapV2RouterAddress;
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_uniswapV2RouterAddress); 
        uniswapV2PairAddress = IUniswapFactory(_uniswapV2Router.factory()).createPair(address(this), _liquidityTokenAddress);

        emit CommunityIssuanceAddressSet(_initialAllocationAddresses.communityIssuanceAddress);
        emit LQTYStakingAddressSet(_lqtyStakingAddress);
        emit MultiSigAddressSet(
            _initialAllocationAddresses.multisigAddressForPUSDReward, 
            _initialAllocationAddresses.multisigAddressForTopDeFi,
            _initialAllocationAddresses.multisigAddressForLiquidity
        );

        // --- Set EIP 2612 Info ---

        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);

        // --- Initial LQTY allocations ---

        uint depositorsAndFrontEndsEntitlement = _10_MILLION.mul(12);
        _mint(_initialAllocationAddresses.communityIssuanceAddress, depositorsAndFrontEndsEntitlement);

        uint LQTYlpRewardsEntitlement = _10_MILLION.mul(12);
        _mint(_initialAllocationAddresses.LQTYlpRewardsAddress, LQTYlpRewardsEntitlement);

        uint LUSDlpRewardsEntitlement = _10_MILLION.mul(2).div(10);
        _mint(_initialAllocationAddresses.LUSDlpRewardsAddress, LUSDlpRewardsEntitlement);

        uint teamAndDevelopers = _10_MILLION.mul(25);
        _mint(_initialAllocationAddresses.lockInHalflifeAddress, teamAndDevelopers);

        uint PUSDRewardEntitlement = _10_MILLION.mul(41);
        _mint(_initialAllocationAddresses.multisigAddressForPUSDReward, PUSDRewardEntitlement);

        uint topDeFiEntitlement = _10_MILLION.mul(9);
        _mint(_initialAllocationAddresses.multisigAddressForTopDeFi, topDeFiEntitlement);
        
        uint liquidityEntitlement = _10_MILLION.mul(8).div(10);
        _mint(_initialAllocationAddresses.multisigAddressForLiquidity, liquidityEntitlement);
    }

    function initWhiteList(
        address _halflifeAddress,
        address _addInitialLiquityAddress,
        address[] memory _otherLPRerwardsAddressList
    ) external onlyOwner {
        checkContract(_halflifeAddress);

        _isExcludedFromFee[address(this)] = true;

        _isExcludedFromFee[communityIssuanceAddress] = true;
        _isExcludedFromFee[lqtyStakingAddress] = true;
        _isExcludedFromFee[uniswapV2RouterAddress] = true;
        
        _isExcludedFromFee[initialAllocationAddresses.multisigAddressForPUSDReward] = true;
        _isExcludedFromFee[initialAllocationAddresses.multisigAddressForTopDeFi] = true;
        _isExcludedFromFee[initialAllocationAddresses.multisigAddressForLiquidity] = true;
        _isExcludedFromFee[initialAllocationAddresses.LQTYlpRewardsAddress] = true;
        _isExcludedFromFee[initialAllocationAddresses.LUSDlpRewardsAddress] = true;

        _isExcludedFromFee[_halflifeAddress] = true;
        _isExcludedFromFee[_addInitialLiquityAddress] = true;

        for(uint i = 0; i < _otherLPRerwardsAddressList.length; i++) {
            address lpRewardsAddress = _otherLPRerwardsAddressList[i];
            checkContract(lpRewardsAddress);
            _isExcludedFromFee[lpRewardsAddress] = true;
        }

        _renounceOwnership();
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {

        _requireValidRecipient(recipient);

        // Otherwise, standard transfer functionality
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function sendToLQTYStaking(address _sender, uint256 _amount) external override {
        _requireCallerIsLQTYStaking();
        _transfer(_sender, lqtyStakingAddress, _amount);
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view override returns (bytes32) {
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner,
        address spender,
        uint amount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
    external
    override
    {
        require(deadline >= now, 'LQTY: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01',
            domainSeparator(), keccak256(abi.encode(
                _PERMIT_TYPEHASH, owner, spender, amount,
                _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) {// FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private pure returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        bool isExcludedFromFee = (sender == uniswapV2PairAddress || _isExcludedFromFee[sender] || _isExcludedFromFee[recipient]);
        _tokenTransfer(sender, recipient, amount, isExcludedFromFee);
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool isExcludedFromFee) internal {
        if (!isExcludedFromFee) {
            (uint256 stakingFee, uint256 deflationFee) = _calculateFees(amount);
            
            if (deflationFee > 0) {
                _burn(sender, deflationFee);
            }
            
            if (stakingFee > 0) {
                _transferToLqtyStaking(sender, stakingFee);
            }
            
            amount = amount.sub(stakingFee).sub(deflationFee);
        }

        _transferStandard(sender, recipient, amount);
    }

    function _transferToLqtyStaking(address sender, uint256 amount) internal {
        _transferStandard(sender, lqtyStakingAddress, amount);
        ILQTYStaking(lqtyStakingAddress).increaseF_LQTY(amount);
    }

    function _calculateFees(uint256 amount) internal view returns (uint256, uint256){
        
        TransferFee memory transferFee;
        
        if (_totalSupply > transferFeeStage1.threshold) {
            transferFee = transferFeeStage1;
        } else if (_totalSupply > transferFeeStage2.threshold) {
            transferFee = transferFeeStage2;
        } else {
            transferFee = transferFeeStage3;
        }
        
        uint256 stakingFee = amount.mul(transferFee.stakingFee).div(transferFeeDenominator);
        uint256 deflationFee = amount.mul(transferFee.deflationFee).div(transferFeeDenominator);
        return (stakingFee, deflationFee);
    }

    function _transferStandard(address sender, address recipient, uint256 amount) internal {
        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        _totalSupply = _totalSupply.sub(amount);
        _balances[account] = _balances[account].sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }


    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) &&
            _recipient != address(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        require(
            _recipient != communityIssuanceAddress &&
            _recipient != lqtyStakingAddress,
            "LQTY: Cannot transfer tokens directly to the community issuance or staking contract"
        );
    }

    function _requireCallerIsLQTYStaking() internal view {
        require(msg.sender == lqtyStakingAddress, "LQTYToken: caller must be the LQTYStaking contract");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    function version() external view override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external view override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }

    receive() external payable {}
}
