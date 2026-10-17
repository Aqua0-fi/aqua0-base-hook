// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenFactory} from "../src/tokens/TokenFactory.sol";
import {FaucetToken} from "../src/tokens/FaucetToken.sol";

contract TokenFactoryTest is Test {
    TokenFactory factory;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new TokenFactory();
    }

    function test_createToken_andFaucet() public {
        vm.prank(alice);
        FaucetToken t = FaucetToken(factory.createToken("Edge City Dollar", "ECD", 6, 0));
        assertEq(t.name(), "Edge City Dollar");
        assertEq(t.symbol(), "ECD");
        assertEq(t.decimals(), 6);
        assertEq(t.balanceOf(alice), 1_000_000e6);
        assertEq(t.faucetAmount(), 10_000e6);
        assertTrue(factory.isFactoryToken(address(t)));
        assertEq(factory.tokenCount(), 1);

        vm.prank(bob);
        t.faucet();
        assertEq(t.balanceOf(bob), 10_000e6);
        t.faucetTo(bob);
        assertEq(t.balanceOf(bob), 20_000e6);

        vm.prank(bob);
        vm.expectRevert(FaucetToken.OnlyCreator.selector);
        t.mint(bob, 1);
        vm.prank(alice);
        t.mint(bob, 5);
    }

    function test_customFaucetAmount() public {
        FaucetToken t = FaucetToken(factory.createToken("Vibes", "VIBE", 18, 42));
        assertEq(t.faucetAmount(), 42e18);
    }

    function test_validation() public {
        vm.expectRevert(TokenFactory.InvalidName.selector);
        factory.createToken("", "X", 18, 0);
        vm.expectRevert(TokenFactory.InvalidSymbol.selector);
        factory.createToken("X", "THIS_SYMBOL_IS_TOO_LONG", 18, 0);
        vm.expectRevert(TokenFactory.InvalidDecimals.selector);
        factory.createToken("X", "X", 19, 0);
    }
}
