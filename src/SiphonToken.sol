// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SIPHON (SIPH)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no mint path, no burn hook, no pause, no fee and no
/// transfer restriction: after the constructor returns the token is a plain OpenZeppelin ERC-20.
/// @dev The Solidity identifier is `SiphonToken` (the launch records it as 32 bytes); the token's
/// own `name()` is "SIPHON" and `symbol()` is "SIPH". Supply can never grow: `_mint` is reachable
/// only from the constructor. Supply can never shrink either: no burn is exposed.
contract SiphonToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "SIPHON";

    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SIPH";

    /// @notice Decimals, the ERC-20 default inherited from OpenZeppelin.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole-token supply before scaling by decimals: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS;

    /// @notice Emitted once, from the constructor, with the recipient of the whole supply.
    event SupplyMinted(address indexed recipient, uint256 amount);

    /// @dev Mints `TOTAL_SUPPLY` to `msg.sender`. At launch `msg.sender` is the factory, which
    /// then distributes the supply (swarm share, pool seed, remainder). The constructor calls no
    /// other contract and requires nothing to have code, so it runs on an empty chain.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }
}
