// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

interface IAdminTransfer {
    function transferShares(address from, address to, uint256 amount) external;
}
