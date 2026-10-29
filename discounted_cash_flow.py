import os
import yfinance as yf
import numpy as np
import warnings
from datetime import datetime
warnings.filterwarnings('ignore')

RISK_FREE_RATE   = 0.105
MARKET_RETURN    = 0.16
GROWTH_RATE      = 0.06
PERPETUAL_GROWTH = 0.045
FORECAST_YEARS   = 5
DEFAULT_TAX_RATE = 0.27
WACC_MIN         = 0.11
WACC_MAX         = 0.18
OUTPUT_FOLDER    = "Discounted Cash Flow"

tickers = [
    "NPN.JO", "CFR.JO", "FSR.JO", "SBK.JO", "AGL.JO", "BIL.JO", "MTN.JO", "VOD.JO", "CPI.JO", "NED.JO",
    "ABG.JO", "SHF.JO", "SOL.JO", "PPC.JO", "IMP.JO", "AMS.JO", "SAP.JO", "WHL.JO", "MRP.JO", "TRU.JO",
    "ARI.JO", "ANG.JO", "APN.JO", "BAT.JO", "CML.JO", "DSBP.JO", "DRD.JO", "EXX.JO", "TFG.JO", "GRT.JO",
    "INL.JO", "JSE.JO", "KIO.JO", "TGA.JO", "MTH.JO", "AFE.JO", "AFT.JO", "OUT.JO", "TKG.JO", "SLM.JO",
    "SSW.JO", "SPP.JO", "SHP.JO", "PIK.JO"
]
tickers = list(dict.fromkeys(tickers))

os.makedirs(OUTPUT_FOLDER, exist_ok=True)
date_stamp = datetime.now().strftime("%Y%m%d")

fx_cache = {}

def fx_to_zar(currency):
    """Multiplier to convert financial statement currency into ZAR."""
    if currency in (None, "ZAR"):
        return 1.0
    if currency == "ZAc":
        return 0.01
    if currency in fx_cache:
        return fx_cache[currency]
    rate = np.nan
    try:
        h = yf.Ticker(f"{currency}ZAR=X").history(period="5d")["Close"].dropna()
        rate = float(h.iloc[-1])
    except Exception:
        pass
    fx_cache[currency] = rate
    return rate

def get_row(df, names):
    """Latest non-null value for the first matching row name."""
    if df is None or df.empty:
        return np.nan
    df = df.sort_index(axis=1, ascending=False)
    for n in names:
        if n in df.index:
            s = df.loc[n].dropna()
            if len(s):
                return float(s.iloc[0])
    return np.nan

def nz(x, default=0.0):
    return default if x is None or (isinstance(x, float) and np.isnan(x)) else x

def fmt_large(v):
    av, sign = abs(v), "-" if v < 0 else ""
    if av >= 1e12: return f"{sign}{av/1e12:.2f}T"
    if av >= 1e9:  return f"{sign}{av/1e9:.2f}B"
    if av >= 1e6:  return f"{sign}{av/1e6:.2f}M"
    if av >= 1e3:  return f"{sign}{av/1e3:.2f}K"
    return f"{sign}{av:.2f}"

print(f"Total JSE tickers to analyze: {len(tickers)}")

success, failed_tickers = 0, []
reports = []

for ticker in tickers:
    try:
        stock = yf.Ticker(ticker)
        info = stock.info
        income = stock.financials
        balance = stock.balance_sheet
        cashflow = stock.cashflow

        if income is None or income.empty or balance is None or balance.empty:
            print(f"Skipping {ticker}: No financial statements")
            failed_tickers.append(ticker)
            continue

        company_name = info.get("longName", info.get("shortName", ticker.replace(".JO", "")))

        hist = stock.history(period="5d")["Close"].dropna()
        if len(hist) == 0:
            print(f"Skipping {ticker}: No price data")
            failed_tickers.append(ticker)
            continue
        current_price = float(hist.iloc[-1]) / 100

        fin_currency = info.get("financialCurrency", "ZAR")
        fx = fx_to_zar(fin_currency)
        if np.isnan(fx):
            print(f"Skipping {ticker}: No FX rate for {fin_currency}")
            failed_tickers.append(ticker)
            continue

        ebit          = nz(get_row(income, ["EBIT", "Operating Income"])) * fx
        tax_expense   = nz(get_row(income, ["Tax Provision", "Income Tax Expense"])) * fx
        pretax_income = nz(get_row(income, ["Pretax Income"])) * fx
        interest_exp  = abs(nz(get_row(income, ["Interest Expense", "Interest Expense Non Operating"]))) * fx
        net_income    = nz(get_row(income, ["Net Income", "Net Income Common Stockholders"])) * fx

        depreciation  = nz(get_row(cashflow, ["Depreciation And Amortization", "Reconciled Depreciation",
                                              "Depreciation Amortization Depletion"])) * fx
        capex         = -abs(nz(get_row(cashflow, ["Capital Expenditure", "Purchase Of PPE"]))) * fx
        cfo           = get_row(cashflow, ["Operating Cash Flow", "Cash Flow From Continuing Operating Activities"]) * fx
        wc_row        = get_row(cashflow, ["Change In Working Capital"]) * fx

        total_debt    = nz(get_row(balance, ["Total Debt"])) * fx
        cash          = nz(get_row(balance, ["Cash And Cash Equivalents",
                                             "Cash Cash Equivalents And Short Term Investments"])) * fx
        cur_assets    = nz(get_row(balance, ["Current Assets", "Total Current Assets"])) * fx
        cur_liab      = nz(get_row(balance, ["Current Liabilities", "Total Current Liabilities"])) * fx
        net_ppe       = nz(get_row(balance, ["Net PPE", "Properties"])) * fx

        shares = info.get("sharesOutstanding")
        if not shares:
            shares = get_row(balance, ["Ordinary Shares Number", "Share Issued"])
        shares = nz(shares, 0.0)

        beta = nz(info.get("beta"), 1.0)
        market_cap = current_price * shares if shares > 0 else nz(info.get("marketCap"), 0.0)

        if shares <= 0:
            print(f"Skipping {ticker}: No share count")
            failed_tickers.append(ticker)
            continue

        eff_tax = min(max(tax_expense / pretax_income, 0), 0.60) if pretax_income != 0 else DEFAULT_TAX_RATE

        if not np.isnan(wc_row):
            wc_cash = wc_row
        elif not np.isnan(cfo):
            wc_cash = cfo - (net_income + depreciation)
        else:
            wc_cash = 0.0

        nopat = ebit * (1 - eff_tax)
        fcff_primary = nopat + depreciation + capex + wc_cash
        fcff_fallback = (net_income + interest_exp * (1 - eff_tax)) + depreciation + capex + wc_cash
        fcff = fcff_fallback if fcff_primary <= 0 else fcff_primary

        cost_of_equity = RISK_FREE_RATE + beta * (MARKET_RETURN - RISK_FREE_RATE)
        cost_of_debt = (interest_exp / total_debt) * (1 - eff_tax) if total_debt != 0 else 0.0
        total_weight = total_debt + market_cap
        w_equity = market_cap / total_weight if total_weight != 0 else 1.0
        w_debt = total_debt / total_weight if total_weight != 0 else 0.0
        wacc_raw = w_equity * cost_of_equity + w_debt * cost_of_debt
        wacc = min(max(wacc_raw, WACC_MIN), WACC_MAX)

        invested_capital = cur_assets - cur_liab + net_ppe
        roic = nopat / invested_capital if invested_capital != 0 else 0.0
        excess_returns = roic - wacc

        sum_pv_fcff = sum(
            (fcff * (1 + GROWTH_RATE) ** t) / (1 + wacc) ** t
            for t in range(1, FORECAST_YEARS + 1)
        )
        last_fcff = fcff * (1 + GROWTH_RATE) ** FORECAST_YEARS
        terminal_value = (last_fcff * (1 + PERPETUAL_GROWTH)) / (wacc - PERPETUAL_GROWTH) if wacc > PERPETUAL_GROWTH else 0.0
        pv_terminal = terminal_value / (1 + wacc) ** FORECAST_YEARS

        total_pv = sum_pv_fcff + pv_terminal
        equity_value = total_pv + cash - total_debt
        fair_value_ps = equity_value / shares

        upside_pct = ((fair_value_ps - current_price) / current_price) * 100 if current_price > 0 else 0.0
        mos_pct = ((fair_value_ps - current_price) / fair_value_ps) * 100 if fair_value_ps != 0 else 0.0
        is_undervalued = fair_value_ps > current_price
        verdict = "UNDERVALUED" if is_undervalued else "OVERVALUED"

        lines = [
            "=" * 60,
            "AMARE CAPITAL MANAGEMENT - VALUATION",
            "=" * 60,
            f"Company:            {company_name}",
            f"Ticker:             {ticker}",
            f"Date:               {datetime.now().strftime('%Y-%m-%d %H:%M')}",
            f"Financial Currency: {fin_currency} (converted to ZAR)",
            "",
            "--- VERDICT ---",
            f"Verdict:            {verdict}",
            f"Current Price:      R{current_price:,.2f}",
            f"Fair Value / Share: R{fair_value_ps:,.2f}",
            f"Upside / Downside:  {upside_pct:.2f}%",
            f"Margin of Safety:   {mos_pct:.2f}%",
            f"MoS Band (+/-20%):  R{fair_value_ps * 0.8:,.2f} - R{fair_value_ps * 1.2:,.2f}",
            "",
            "--- DCF COMPONENTS ---",
            f"FCFF:               R{fmt_large(fcff)}",
            f"Terminal Value:     R{fmt_large(terminal_value)}",
            f"PV(Terminal Value): R{fmt_large(pv_terminal)}",
            f"Sum PV(FCFFs):      R{fmt_large(sum_pv_fcff)}",
            f"Cash:               R{fmt_large(cash)}",
            f"Total Debt:         R{fmt_large(total_debt)}",
            f"Equity Value:       R{fmt_large(equity_value)}",
            f"Shares Outstanding: {shares:,.0f}",
            "",
            "--- KEY METRICS ---",
            f"WACC:               {wacc * 100:.2f}%",
            f"Cost of Equity:     {cost_of_equity * 100:.2f}%",
            f"ROIC:               {roic * 100:.2f}%",
            f"Excess Returns:     {excess_returns * 100:.2f}%",
            f"Beta:               {beta:.2f}",
            f"Eff. Tax Rate:      {eff_tax * 100:.2f}%",
            "",
            "--- ASSUMPTIONS ---",
            f"Risk-Free Rate:     {RISK_FREE_RATE * 100:.1f}%",
            f"Market Return:      {MARKET_RETURN * 100:.1f}%",
            f"Near-Term Growth:   {GROWTH_RATE * 100:.1f}%",
            f"Perpetual Growth:   {PERPETUAL_GROWTH * 100:.1f}%",
            f"Forecast Years:     {FORECAST_YEARS}",
            f"WACC Clamp:         {WACC_MIN * 100:.0f}% - {WACC_MAX * 100:.0f}%",
        ]
        if fcff <= 0:
            lines += ["", "WARNING: FCFF is negative or zero - DCF result is not meaningful."]
        lines += ["", "For research only. Not financial advice.", "Data: Finance (annual statements)"]

        reports.append("\n".join(lines))

        success += 1
        print(f"Processed: {ticker} - {company_name[:30]} - {verdict} (FV R{fair_value_ps:,.2f} vs R{current_price:,.2f})")

    except Exception as e:
        print(f"Error processing {ticker}: {str(e)}")
        failed_tickers.append(ticker)

if reports:
    filepath = os.path.join(OUTPUT_FOLDER, f"JSE_DCF_{date_stamp}.txt")
    separator = "\n\n" + "-" * 60 + "\n\n"
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(separator.join(reports))
    print(f"Saved: {filepath}")

print(f"\nSuccessfully processed {success} JSE stocks")
if failed_tickers:
    print(f"Failed to process {len(failed_tickers)} tickers: {failed_tickers}")
print(f"Files saved to: {OUTPUT_FOLDER}/")