// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceProduct} from "../../src/vault/InferenceProduct.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeRouter {
    MockUSDC public usdc;
    uint256 public received;

    constructor(address _usdc) {
        usdc = MockUSDC(_usdc);
    }

    function receiveUSDC(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract InferenceProductTest is Test {
    MockUSDC mockUsdc;
    MockFeeRouter feeRouter;
    InferenceProduct product;

    address owner = address(this);
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    uint256 constant CAPACITY = 100e18; // 100 DIEM available

    function setUp() public {
        mockUsdc = new MockUSDC();
        feeRouter = new MockFeeRouter(address(mockUsdc));
        product = new InferenceProduct(address(mockUsdc), address(feeRouter), owner);
        product.setCapacity(CAPACITY);
    }

    // --- setCapacity ---

    function test_setCapacity_updatesPool() public view {
        assertEq(product.totalCapacityDIEM(), CAPACITY);
        assertEq(product.availableCapacityDIEM(), CAPACITY);
    }

    function test_setCapacity_cannotGoBelowActive() public {
        _fundAndBuy(buyer, 50e18, 7);
        vm.expectRevert("below active allocations");
        product.setCapacity(40e18);
    }

    function test_setCapacity_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert();
        product.setCapacity(200e18);
    }

    // --- buy ---

    function test_buy_allocatesCapacity() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 30);
        assertEq(product.allocatedDIEM(), 10e18);
        assertEq(product.availableCapacityDIEM(), 90e18);

        InferenceProduct.Purchase memory p = product.getPurchase(id);
        assertEq(p.buyer, buyer);
        assertEq(p.diemAmount, 10e18);
        assertEq(p.numDays, 30);
        assertFalse(p.released);
    }

    function test_buy_priceRoutedToFeeRouter() public {
        // 10 DIEM × 30 days × $0.80 = $240
        uint256 expectedPrice = 10 * 30 * 0.8e6;
        _fundAndBuy(buyer, 10e18, 30);
        assertEq(feeRouter.received(), expectedPrice);
        assertEq(product.totalRevenueUSDC(), expectedPrice);
    }

    function test_buy_expiresCorrectly() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        InferenceProduct.Purchase memory p = product.getPurchase(id);
        assertEq(p.expiresAt, block.timestamp + 7 days);
    }

    function test_buy_revertsOnInsufficientCapacity() public {
        uint256 price = product.quotePrice(CAPACITY + 1e18, 1);
        mockUsdc.mint(buyer, price);
        vm.startPrank(buyer);
        mockUsdc.approve(address(product), price);
        vm.expectRevert(
            abi.encodeWithSelector(
                InferenceProduct.InsufficientCapacity.selector, CAPACITY + 1e18, CAPACITY
            )
        );
        product.buy(CAPACITY + 1e18, 1, 0);
        vm.stopPrank();
    }

    function test_buy_revertsOnZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(InferenceProduct.ZeroAmount.selector);
        product.buy(0, 7, 0);
    }

    function test_buy_multipleBuyersSharePool() public {
        _fundAndBuy(buyer, 60e18, 7);
        _fundAndBuy(buyer2, 40e18, 14);
        assertEq(product.allocatedDIEM(), 100e18);
        assertEq(product.availableCapacityDIEM(), 0);
    }

    // --- releaseExpired ---

    function test_releaseExpired_freesCapacity() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        vm.warp(block.timestamp + 7 days + 1);
        product.releaseExpired(id);
        assertEq(product.allocatedDIEM(), 0);
        assertEq(product.availableCapacityDIEM(), CAPACITY);
        assertTrue(product.getPurchase(id).released);
    }

    function test_releaseExpired_revertsIfNotExpired() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(InferenceProduct.NotExpired.selector);
        product.releaseExpired(id);
    }

    function test_releaseExpired_revertsIfAlreadyReleased() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        vm.warp(block.timestamp + 7 days + 1);
        product.releaseExpired(id);
        vm.expectRevert(InferenceProduct.AlreadyReleased.selector);
        product.releaseExpired(id);
    }

    function test_releaseExpired_anyoneCanCall() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(makeAddr("anyone"));
        product.releaseExpired(id);
        assertEq(product.allocatedDIEM(), 0);
    }

    // --- forceRelease ---

    function test_forceRelease_ownerCanCancelActive() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        product.forceRelease(id);
        assertEq(product.allocatedDIEM(), 0);
        assertTrue(product.getPurchase(id).released);
    }

    function test_forceRelease_onlyOwner() public {
        uint256 id = _fundAndBuy(buyer, 10e18, 7);
        vm.prank(buyer);
        vm.expectRevert();
        product.forceRelease(id);
    }

    // --- marketplace config ---

    function test_setMarketplaceConfig_storesValues() public {
        string[] memory models = new string[](2);
        models[0] = "llama-3.3-70b";
        models[1] = "mistral-nemo";
        product.setMarketplaceConfig(models, 0.5e6, 1.5e6, 1_000_000, 500);

        assertEq(product.getModelIds()[0], "llama-3.3-70b");
        (uint256 pIn, uint256 pOut, uint256 maxT, uint256 platformFee) =
            product.getMarketplaceConfig();
        assertEq(pIn, 0.5e6);
        assertEq(pOut, 1.5e6);
        assertEq(maxT, 1_000_000);
        assertEq(platformFee, 500);
    }

    function test_setPricePerDiemDay_affectsQuote() public {
        product.setPricePerDiemDay(1.0e6); // $1.00/DIEM/day
        // 10 DIEM × 7 days × $1.00 = $70
        assertEq(product.quotePrice(10e18, 7), 70e6);
    }

    // --- price guard ---

    function test_buy_maxPriceUSDC_revertsIfExceeded() public {
        uint256 price = product.quotePrice(10e18, 30);
        mockUsdc.mint(buyer, price);
        vm.startPrank(buyer);
        mockUsdc.approve(address(product), price);
        vm.expectRevert(
            abi.encodeWithSelector(InferenceProduct.PriceExceeded.selector, price, price - 1)
        );
        product.buy(10e18, 30, price - 1);
        vm.stopPrank();
    }

    function test_buy_maxPriceUSDC_zeroMeansNoCap() public {
        _fundAndBuy(buyer, 10e18, 30); // maxPrice=0, should not revert
    }

    function test_buy_revertsOnZeroDuration() public {
        vm.prank(buyer);
        vm.expectRevert(InferenceProduct.ZeroDuration.selector);
        product.buy(10e18, 0, 0);
    }

    // --- critical: fractional-DIEM pricing (divide-before-multiply was wrong) ---

    function test_computePrice_fractionalDIEM_notZero() public view {
        // 0.5 DIEM × 1 day × $0.80/DIEM/day = $0.40 (4e5 USDC)
        // Old formula: (0.5e18 / 1e18) * 1 * 0.80e6 = 0 * 0.80e6 = 0  ← exploit
        // New formula: (0.5e18 * 1 * 0.80e6) / 1e18 = 4e5              ← correct
        assertEq(product.quotePrice(0.5e18, 1), 0.4e6);
    }

    function test_buy_fractionalDIEM_chargesCorrectly() public {
        // Confirm sub-1e18 purchases pay non-zero USDC
        uint256 price = product.quotePrice(0.999e18, 1);
        assertGt(price, 0, "fractional DIEM must not be free");
        mockUsdc.mint(buyer, price);
        vm.startPrank(buyer);
        mockUsdc.approve(address(product), price);
        product.buy(0.999e18, 1, 0);
        vm.stopPrank();
        assertGt(feeRouter.received(), 0);
    }

    // --- views ---

    function test_quotePrice_defaultPricing() public view {
        // 50 DIEM × 14 days × $0.80 = $560
        assertEq(product.quotePrice(50e18, 14), 50 * 14 * 0.8e6);
    }

    // --- helpers ---

    function _fundAndBuy(address _buyer, uint256 diemAmount, uint256 numDays)
        internal
        returns (uint256 id)
    {
        uint256 price = product.quotePrice(diemAmount, numDays);
        mockUsdc.mint(_buyer, price);
        vm.startPrank(_buyer);
        mockUsdc.approve(address(product), price);
        id = product.buy(diemAmount, numDays, 0);
        vm.stopPrank();
    }
}
