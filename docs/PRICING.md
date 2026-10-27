# Owner-approved commercial settings

The owner confirmed these existing settings on October 26, 2026. Approval covers the pricing and published splits; **it does not authorize live billing, production data changes, or production deployment**.

| Package | Base coins | Bonus | Total credited | USD |
|---|---:|---:|---:|---:|
| Starter | 100 | 0 | 100 | 0.99 |
| Popular | 500 | 50 | 550 | 4.99 |
| Value | 1,200 | 200 | 1,400 | 9.99 |
| Pro | 3,500 | 700 | 4,200 | 24.99 |
| Kingdom | 7,000 | 1,500 | 8,500 | 49.99 |
| Anointed | 15,000 | 5,000 | 20,000 | 99.99 |

Creator Pro remains **$19/month**. Existing published creator splits remain:

- Live gifts: platform 80%, creator 20%.
- AuthorityShop: platform 20%, creator 77%, processing allocation 3%.
- Creator audience subscriptions: platform 30%, creator 62%, processing allocation 8%.
- Tithes: platform 5%, ministry 95%.

The existing Creator Pro software-plan copy allocates its revenue to the platform; it is distinct from creator audience subscriptions. This implementation handles the software-plan entitlement and Creator Analytics. Creator audience subscriptions, tithes, simulcasting, and priority-CDN services are not newly invented checkout products. They require their intended service/benefit configuration before they can be advertised as available. `PRO_ENABLED` remains false by default until that acceptance review is complete.

Gift and digital-resource settlement use the existing nominal coin value and creator percentages. Creator amounts are rounded down to whole cents; the fractional-cent remainder stays with the platform. Actual payment-processor fees may differ from the published allocation and must be reconciled operationally; they do not silently reduce the approved creator percentage.

`tests/pricing.test.mjs` checks frontend coin prices/totals against the trusted server catalog, the $19 monthly price, and the implemented gift/shop settlement percentages. No new pricing or paid integration is introduced.
