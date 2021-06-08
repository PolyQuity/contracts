// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/IERC20.sol";
import "../Dependencies/IERC2612.sol";

interface ILQTYToken is IERC20, IERC2612 {

    // --- Events ---

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event LQTYStakingAddressSet(address _lqtyStakingAddress);
    event LockupContractFactoryAddressSet(address _lockupContractFactoryAddress);
    event SwapAndLiquify(uint256 amountSwapped, uint256 ftmReceived, uint256 amountIntoLiqudity);

    // --- Functions ---

    function sendToLQTYStaking(address _sender, uint256 _amount) external;

    function getDeploymentStartTime() external view returns (uint256);
}
