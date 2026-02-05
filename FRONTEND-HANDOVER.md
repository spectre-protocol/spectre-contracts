# Frontend Handover

Everything the frontend needs to integrate GrimSwap private swaps.

## Contract Addresses (Unichain Sepolia, Chain ID: 1301)

```typescript
const CONTRACTS = {
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  poolSwapTest: "0x9140a78c1A137c7fF1c151EC8231272aF78a99A4",
  grimPool: "0xEAB5E7B4e715A22E8c114B7476eeC15770B582bb",
  grimSwapZK: "0xeB72E2495640a4B83EBfc4618FD91cc9beB640c4",  // Hook address
  grimSwapRouter: "0xC13a6a504da21aD23c748f08d3E991621D42DA4F",
  groth16Verifier: "0xF7D14b744935cE34a210D7513471a8E6d6e696a0",
};
```

## Relayer

- URL: `http://localhost:3001` (dev)
- Endpoints: `GET /health`, `GET /info`, `POST /relay`
- See `grimswap-relayer/README.md` for full API docs

## Frontend Flow (Step by Step)

### 1. Deposit ETH to GrimPool

```typescript
// User deposits ETH with a Poseidon commitment
const commitment = poseidonHash([nullifier, secret, amount]);
await grimPool.deposit(toBytes32(commitment), { value: amount });
```

**ABI:**
```json
{
  "name": "deposit",
  "inputs": [{ "name": "commitment", "type": "bytes32" }],
  "stateMutability": "payable"
}
```

### 2. Build Poseidon Merkle Tree (Client-Side)

```typescript
import { buildPoseidon } from "circomlibjs";

// Build tree with all deposits (read Deposit events from GrimPool)
const tree = new PoseidonMerkleTree(20);
await tree.initialize();
// Insert all commitments from Deposit events
for (const commitment of allCommitments) {
  await tree.insert(commitment);
}
const proof = tree.getProof(myLeafIndex);
```

### 3. Add Merkle Root (Testnet Only)

```typescript
// On testnet, the depositor adds their own root
await grimPool.addKnownRoot(toBytes32(proof.root));
```

### 4. Generate Stealth Address

```typescript
// Random stealth address (unlinkable to user)
const stealthPrivateKey = randomFieldElement();
const stealthAddress = keccak256(toBytes32(stealthPrivateKey)).slice(-40);
```

### 5. Generate ZK Proof (Client-Side)

```typescript
import * as snarkjs from "snarkjs";

const input = {
  merkleRoot: proof.root.toString(),
  nullifierHash: note.nullifierHash.toString(),
  recipient: BigInt(stealthAddress).toString(),
  relayer: BigInt(relayerAddress).toString(),
  relayerFee: "10", // basis points
  swapAmountOut: note.amount.toString(),
  secret: note.secret.toString(),
  nullifier: note.nullifier.toString(),
  depositAmount: note.amount.toString(),
  pathElements: proof.pathElements.map(e => e.toString()),
  pathIndices: proof.pathIndices,
};

const { proof: zkProof, publicSignals } = await snarkjs.groth16.fullProve(
  input,
  "path/to/privateSwap.wasm",
  "path/to/privateSwap.zkey"
);
```

**Circuit files needed** (from `grimswap-circuits/build/`):
- `privateSwap_js/privateSwap.wasm` - witness generator
- `privateSwap.zkey` - proving key

### 6. Send to Relayer

```typescript
const response = await fetch("http://localhost:3001/relay", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    proof: {
      a: [zkProof.pi_a[0], zkProof.pi_a[1]],
      b: [
        [zkProof.pi_b[0][0], zkProof.pi_b[0][1]],
        [zkProof.pi_b[1][0], zkProof.pi_b[1][1]],
      ],
      c: [zkProof.pi_c[0], zkProof.pi_c[1]],
    },
    publicSignals,
    swapParams: {
      poolKey: {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "<output_token_address>",
        fee: 3000,       // pool fee tier
        tickSpacing: 60, // pool tick spacing
        hooks: CONTRACTS.grimSwapZK,
      },
      zeroForOne: true,  // true for ETH -> Token
      amountSpecified: (-depositAmount).toString(), // negative = exact input
      sqrtPriceLimitX96: "4295128740", // MIN_SQRT_PRICE + 1 for zeroForOne
    },
  }),
});

const result = await response.json();
// result.txHash, result.blockNumber, result.gasUsed
```

### 7. Verify Receipt

```typescript
// Check output token balance at stealth address
const balance = await token.balanceOf(stealthAddress);

// Check nullifier was spent (prevents reuse)
const spent = await grimPool.isSpent(toBytes32(note.nullifierHash));
```

## Creating a Pool

The frontend should create pools. The GrimSwapZK hook supports **any** pool with its address as the hook.

### Pool Key Format

```typescript
const poolKey = {
  currency0: "0x0000000000000000000000000000000000000000", // ETH (must be lower address)
  currency1: tokenAddress,  // The other token
  fee: 3000,               // Fee tier: 500, 3000, or 10000
  tickSpacing: 60,         // Must match fee: 10, 60, or 200
  hooks: CONTRACTS.grimSwapZK, // Always use the GrimSwapZK hook
};
```

### Initialize Pool

```typescript
// Call PoolManager.initialize
await poolManager.initialize(poolKey, sqrtPriceX96);
```

### Add Liquidity

**IMPORTANT**: Do NOT use the `PoolTestHelper.addLiquidity()` for tokens with different decimals (e.g., ETH 18 dec / USDC 6 dec). The simplified liquidity calculation breaks. Instead, use `DirectLiquidityAdder` pattern with explicit `liquidityDelta`.

See `grimswap-contracts/script/AddLiquidityDirect.s.sol` for the correct pattern.

### Fee/TickSpacing Reference

| Fee | TickSpacing | Use Case |
|-----|-------------|----------|
| 500 | 10 | Stable pairs |
| 3000 | 60 | Most pairs |
| 10000 | 200 | Exotic pairs |

### sqrtPriceX96 for ETH/USDC

For ETH = currency0, USDC = currency1 (6 decimals):
- $2000/ETH: `3543191142285914205922034`
- $3000/ETH: `4339505028714986015908034`

Formula: `sqrt(price_usdc * 10^6 / 10^18) * 2^96`

## Dual-Mode Hook

The GrimSwapZK hook supports both regular and private swaps on the same pool:

- **Regular swap**: Pass empty `hookData` (`0x`) - no ZK verification
- **Private swap**: Pass encoded ZK proof as `hookData` - full verification + stealth routing

## ABIs

### GrimPool

```json
[
  { "name": "deposit", "inputs": [{"name": "commitment", "type": "bytes32"}], "stateMutability": "payable" },
  { "name": "addKnownRoot", "inputs": [{"name": "root", "type": "bytes32"}], "stateMutability": "nonpayable" },
  { "name": "isKnownRoot", "inputs": [{"name": "root", "type": "bytes32"}], "outputs": [{"type": "bool"}], "stateMutability": "view" },
  { "name": "isSpent", "inputs": [{"name": "nullifierHash", "type": "bytes32"}], "outputs": [{"type": "bool"}], "stateMutability": "view" },
  { "name": "getDepositCount", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view" }
]
```

### GrimPool Events

```json
[
  { "name": "Deposit", "inputs": [
    {"name": "commitment", "type": "bytes32", "indexed": true},
    {"name": "leafIndex", "type": "uint32"},
    {"name": "timestamp", "type": "uint256"}
  ]}
]
```

### GrimSwapZK Events

```json
[
  { "name": "StealthPayment", "inputs": [
    {"name": "stealthAddress", "type": "address", "indexed": true},
    {"name": "token", "type": "address", "indexed": true},
    {"name": "amount", "type": "uint256"},
    {"name": "fee", "type": "uint256"},
    {"name": "relayer", "type": "address"}
  ]}
]
```

## Production Test Reference

See `grimswap-test/src/fullZKSwapWithRelayer.ts` for a complete working implementation of the entire flow.

Successful test TX: [`0xca2fa2b5...`](https://unichain-sepolia.blockscout.com/tx/0xca2fa2b55af5a94f9d1ea3712aa08c847154a4327172172a4f1bfa861d0e4461)
