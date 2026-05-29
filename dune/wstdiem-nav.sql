-- wstDIEM NAV (DIEM per 1 wstDIEM) from on-chain Deposit events
-- Deposit event: Deposit(caller, owner, assets, shares)
-- topic0 = keccak256("Deposit(address,address,uint256,uint256)")

WITH deposits AS (
    SELECT
        block_time,
        bytea2numeric(data) AS assets,
        bytea2numeric(topic3) AS shares
    FROM evm_base.logs
    WHERE contract_address = LOWER('{VAULT_ADDRESS}')
      AND topic0 = '0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7'
      AND bytea2numeric(topic3) > 0
)
SELECT
    DATE_TRUNC('hour', block_time)       AS hour,
    AVG(assets * 1e18 / shares)          AS nav_diem_per_wstdiem
FROM deposits
GROUP BY 1
ORDER BY 1 DESC
