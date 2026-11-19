// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockERC20
/// @notice Minimal ERC-20 used for the demo position token (TOKEN) and the
///         quote token (QUOTE) on Base Sepolia. Testnet only — anyone can mint.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to_, uint256 amount_) external {
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        require(allowed >= amount_, "MockERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from_][msg.sender] = allowed - amount_;
        }
        _transfer(from_, to_, amount_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        require(to_ != address(0), "MockERC20: transfer to zero address");
        require(balanceOf[from_] >= amount_, "MockERC20: insufficient balance");
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
