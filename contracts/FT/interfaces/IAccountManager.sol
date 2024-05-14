// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

interface IAccountManager {
    function freezeAccount(address account, string memory memo) external;

    function unfreezeAccount(address account, string memory memo) external;

    function isAccountFrozen(address account) external view returns (bool);

    function removeAccountPostRecovery(
        address from,
        address to
    ) external;
}
