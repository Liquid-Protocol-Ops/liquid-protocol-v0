-- VOL ratio: vault-owned wstDIEM / total wstDIEM supply
-- Approximated via Transfer events

WITH vault_wstdiem AS (
    SELECT
        block_time,
        CASE
            WHEN "to"   = LOWER('{VAULT_ADDRESS}') THEN value / 1e18
            WHEN "from" = LOWER('{VAULT_ADDRESS}') THEN -value / 1e18
        END AS delta
    FROM erc20_base.evt_Transfer
    WHERE contract_address = LOWER('{VAULT_ADDRESS}')
      AND ("to" = LOWER('{VAULT_ADDRESS}') OR "from" = LOWER('{VAULT_ADDRESS}'))
),
vault_owned AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        SUM(SUM(delta)) OVER (ORDER BY DATE_TRUNC('day', block_time)) AS vol_shares
    FROM vault_wstdiem
    GROUP BY 1
),
total_supply AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        SUM(SUM(
            CASE
                WHEN "from" = '0x0000000000000000000000000000000000000000'
                     THEN value / 1e18
                WHEN "to"   = '0x0000000000000000000000000000000000000000'
                     THEN -value / 1e18
                ELSE 0
            END
        )) OVER (ORDER BY DATE_TRUNC('day', block_time)) AS total_shares
    FROM erc20_base.evt_Transfer
    WHERE contract_address = LOWER('{VAULT_ADDRESS}')
    GROUP BY 1
)
SELECT
    v.day,
    v.vol_shares,
    t.total_shares,
    v.vol_shares / NULLIF(t.total_shares, 0) AS vol_ratio
FROM vault_owned   v
JOIN total_supply  t USING (day)
ORDER BY v.day DESC
