// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

interface IBunnyVault {
    function deposit(uint256 _amount) external;
    function getRewards() external;
    function withdrawUnderlying(uint256 _amount) external;
    function withdrawAll() external;
}
