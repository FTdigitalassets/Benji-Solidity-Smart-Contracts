// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

interface IRecovery {
    function recoverAccount(
        address from,
        address to,
        string memory memo
    ) external;

    function recoverAsset(
        address from,
        address to,
        uint256 amount,
        string memory memo
    ) external;
}
