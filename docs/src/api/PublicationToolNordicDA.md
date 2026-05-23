# Publicationtoolnordicda

Nordic CCR day-ahead — subset of Core (no `lta`, `netPos`, `allocationConstraint`, `alphaFactor`, `priceSpread`, `scheduledExchanges`) plus `fbDomainShadowPrice`; `d2CF` renamed to `cgmForeCast`; filter key `NonRedundant` replaces `Presolved`.

## Nordic CGM forecast (Nordic d2CF alias)

`GET /publicationtool/nordic/data/cgmForeCast`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_cgm_forecast" prefix-headings="true" />
```

## Nordic congestion income per border

`GET /publicationtool/nordic/data/congestionIncome`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_congestion_income" prefix-headings="true" />
```

## Nordic active-constraint shadow prices

`GET /publicationtool/nordic/data/fbDomainShadowPrice`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_fb_domain_shadow_price" prefix-headings="true" />
```

## Final Nordic FB domain (CNECs + PTDFs)

`GET /publicationtool/nordic/data/finalComputation`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_final_computation" prefix-headings="true" />
```

## Initial Nordic FB domain

`GET /publicationtool/nordic/data/initialComputation`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_initial_computation" prefix-headings="true" />
```

## Nordic max bilateral exchanges

`GET /publicationtool/nordic/data/maxExchanges`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_max_exchanges" prefix-headings="true" />
```

## Nordic min/max net positions per zone

`GET /publicationtool/nordic/data/maxNetPos`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_max_net_positions" prefix-headings="true" />
```

## Pre-final Nordic FB domain

`GET /publicationtool/nordic/data/preFinalComputation`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_prefinal_computation" prefix-headings="true" />
```

## Nordic reference programs

`GET /publicationtool/nordic/data/refprog`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_refprog" prefix-headings="true" />
```

## Nordic default-FBP status

`GET /publicationtool/nordic/data/spanningDefaultFBP`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_spanning_default_fbp" prefix-headings="true" />
```

## Nordic TSO validation reductions

`GET /publicationtool/nordic/data/validationReductions`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_validation_reductions" prefix-headings="true" />
```

## Nordic publication monitoring

`GET /publicationtool/nordic/system/monitoring`

```@raw html
<OAOperation operationId="publicationtool_nordic_da_monitoring" prefix-headings="true" />
```
