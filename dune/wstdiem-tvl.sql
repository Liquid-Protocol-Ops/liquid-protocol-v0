-- wstDIEM Vault TVL (total DIEM held by vault)
-- Replace {VAULT_ADDRESS} with deployed InferenceVault address

WITH diem_transfers AS (
    SELECT
        block_time,
        CASE
            WHEN "to"   = LOWER('{VAULT_ADDRESS}') THEN value / 1e18
            WHEN "from" = LOWER('{VAULT_ADDRESS}') THEN -value / 1e18
        END AS delta
    FROM erc20_base.evt_Transfer
    WHERE contract_address = LOWER('0xF4d97F2da56e8c3098f3a8D538DB630A2606a024')
      AND ("to" = LOWER('{VAULT_ADDRESS}') OR "from" = LOWER('{VAULT_ADDRESS}'))
)
SELECT
    DATE_TRUNC('day', block_time)                                     AS day,
    SUM(SUM(delta)) OVER (ORDER BY DATE_TRUNC('day', block_time))     AS tvl_diem
FROM diem_transfers
GROUP BY 1
ORDER BY 1 DESC
