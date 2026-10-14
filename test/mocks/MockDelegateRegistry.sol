// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal stand-in for delegate.xyz DelegateRegistry v2: one explicit flag per
///         (to, from, contract, tokenId, rights) tuple.
contract MockDelegateRegistry {
    mapping(bytes32 => bool) private _delegations;

    function setDelegate(address to, address from, address contract_, uint256 tokenId, bytes32 rights, bool enabled)
        external
    {
        _delegations[keccak256(abi.encode(to, from, contract_, tokenId, rights))] = enabled;
    }

    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool)
    {
        return _delegations[keccak256(abi.encode(to, from, contract_, tokenId, rights))];
    }
}
