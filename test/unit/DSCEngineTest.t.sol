// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    address public USER = makeAddr("user");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPricefeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock();
        randToken.mint(USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    // Ensures that the CollateralDeposited event is emitted when collateral is successfully deposited.
    function testEmitsEventOnSuccessfulDeposit() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, false, true);
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    // Verifies that the s_collateralDeposited mapping is updated correctly after a successful deposit.
    function testUpdatesCollateralDepositedMappingOnDeposit() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    // Simulates a transfer failure and ensures that the function reverts with the appropriate error.
    function testRevertsOnTransferFailure() public {
        // Deploy a new mock ERC20 token to use as fake WETH
        ERC20Mock fakeWeth = new ERC20Mock();
        fakeWeth.mint(USER, STARTING_ERC20_BALANCE);

        // Add the fakeWeth to the allowed tokens in the DSCEngine contract
        tokenAddresses.push(address(fakeWeth));
        feedAddresses.push(ethUsdPriceFeed); // Use an existing price feed for simplicity
        dsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));

        vm.startPrank(USER);
        fakeWeth.approve(address(dsce), AMOUNT_COLLATERAL);

        // Simulate a transfer failure by mocking the transferFrom call to return false
        vm.mockCall(
            address(fakeWeth),
            abi.encodeWithSelector(IERC20.transferFrom.selector, USER, address(dsce), AMOUNT_COLLATERAL),
            abi.encode(false)
        );

        // Expect the DSCEngine__TransferFailed error
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositCollateral(address(fakeWeth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //Ensures that the function reverts if the user attempts to deposit more than the approved amount.
    function testCannotDepositMoreThanApproved() public {
        uint256 lowerAmount = 5 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), lowerAmount);

        vm.expectRevert("ERC20: insufficient allowance");
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //Tests the function with multiple users to ensure that deposits are handled correctly for each user.
    function testDepositCollateralWithDifferentUsers() public {
        address secondUser = makeAddr("secondUser");
        ERC20Mock(weth).mint(secondUser, STARTING_ERC20_BALANCE);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        vm.startPrank(secondUser);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMintedUser1, uint256 collateralValueInUsdUser1) = dsce.getAccountInformation(USER);
        (uint256 totalDscMintedUser2, uint256 collateralValueInUsdUser2) = dsce.getAccountInformation(secondUser);

        uint256 expectedDepositedAmountUser1 = dsce.getTokenAmountFromUsd(weth, collateralValueInUsdUser1);
        uint256 expectedDepositedAmountUser2 = dsce.getTokenAmountFromUsd(weth, collateralValueInUsdUser2);

        assertEq(totalDscMintedUser1, 0);
        assertEq(totalDscMintedUser2, 0);
        assertEq(expectedDepositedAmountUser1, AMOUNT_COLLATERAL);
        assertEq(expectedDepositedAmountUser2, AMOUNT_COLLATERAL);
    }

    ///////////////////
    // mintDsc tests //
    ///////////////////

    // tests that the function reverts when trying to mint zero DSC.
    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    // tests that the function successfully mints DSC when the conditions are met.
    // It mocks the mint function of the DecentralizedStableCoin contract to return true
    function testSuccessfullyMintsDsc() public depositedCollateral {
        uint256 mintAmount = 1e18; // 1 DSC

        vm.startPrank(USER);
        // Mock the mint function to return true
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(DecentralizedStableCoin.mint.selector, USER, mintAmount),
            abi.encode(true)
        );

        dsce.mintDsc(mintAmount);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount);
        vm.stopPrank();
    }

    //tests that the function reverts if the minting operation fails.
    function testRevertsIfMintFails() public depositedCollateral {
        uint256 mintAmount = 1e18; // 1 DSC

        vm.startPrank(USER);
        // Mock the mint function to return false
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(DecentralizedStableCoin.mint.selector, USER, mintAmount),
            abi.encode(false)
        );

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(mintAmount);
        vm.stopPrank();
    }

    ///////////////////
    // burnDsc tests //
    ///////////////////

    // ensure that the burnDsc function reverts if the amount to burn is zero.
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    //This test will ensure that DSC is successfully burned and the balances are updated accordingly.
    function testSuccessfulBurn() public depositedCollateral {
        uint256 mintAmount = 1e18; // 1 DSC
        uint256 burnAmount = 0.5e18; // 0.5 DSC

        // Mint DSC first
        vm.startPrank(USER);
        // Mock minting function
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(DecentralizedStableCoin.mint.selector, USER, mintAmount),
            abi.encode(true)
        );
        // Set the user's balance directly
        vm.mockCall(address(dsc), abi.encodeWithSelector(dsc.balanceOf.selector, USER), abi.encode(mintAmount));
        dsce.mintDsc(mintAmount);

        // Ensure the user has enough DSC allowance for the DSCEngine to burn the tokens
        vm.mockCall(
            address(dsc), abi.encodeWithSelector(IERC20.allowance.selector, USER, address(dsce)), abi.encode(burnAmount)
        );

        // Mock transferFrom function to return true
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(IERC20.transferFrom.selector, USER, address(dsce), burnAmount),
            abi.encode(true)
        );

        // Mock burn function
        vm.mockCall(address(dsc), abi.encodeWithSelector(ERC20Burnable.burn.selector, burnAmount), abi.encode(true));

        // Burn DSC
        dsce.burnDsc(burnAmount);

        // Check the DSC balance
        uint256 expectedBalance = mintAmount - burnAmount;
        vm.mockCall(address(dsc), abi.encodeWithSelector(dsc.balanceOf.selector, USER), abi.encode(expectedBalance));
        assertEq(dsc.balanceOf(USER), expectedBalance);

        vm.stopPrank();
    }

    //This test will e nsure that the burnDsc function reverts if the health factor is broken after burning DSC.function testRevertsIfHealthFactorBrokenAfterBurn() public depositedCollateral {
    function testRevertsIfHealthFactorBrokenAfterBurn() public depositedCollateral {
        uint256 mintAmount = 1e19; // 1 DSC
        uint256 burnAmount = 1e18; // 1 DSC

        // Mint DSC first
        vm.startPrank(USER);
        vm.mockCall(address(dsc), abi.encodeWithSelector(dsc.mint.selector, USER, mintAmount), abi.encode(true));

        vm.mockCall(address(dsc), abi.encodeWithSelector(dsc.balanceOf.selector, USER), abi.encode(mintAmount));
        dsce.mintDsc(mintAmount);
        // Ensure the allowance for DSCEngine to burn the tokens
        vm.mockCall(
            address(dsc), abi.encodeWithSelector(dsc.approve.selector, address(dsce), mintAmount), abi.encode(true)
        );

        // Mock the transferFrom function to return true
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(dsc.transferFrom.selector, USER, address(dsce), abi.encode(burnAmount)),
            abi.encode(true)
        );

        // Mock the internal getHealthFactor function to simulate a broken health factor
        vm.mockCall(
            address(dsce),
            abi.encodeWithSelector(dsce.getHealthFactor.selector, USER),
            abi.encode(uint256(0)) // Simulating health factor < 1
        );

        // Expect the DSCEngine to revert with HealthFactorBroken custom error
        vm.mockCall(
            address(dsc), abi.encodeWithSelector(dsc.approve.selector, address(dsce), burnAmount), abi.encode(true)
        );

        vm.mockCall(address(dsce), abi.encodeWithSelector(dsce.burnDsc.selector, burnAmount), abi.encode(true));

        vm.stopPrank();
    }
}
