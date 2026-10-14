// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC-20 standing in for VIMD. Etched at VIMD's mainnet address in tests, so name
///         and symbol are left empty on purpose (constructor storage does not survive vm.etch).
contract MockVIMD is ERC20 {
    constructor() ERC20("", "") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
