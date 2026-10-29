import yfinance as yf
import pandas as pd
import numpy as np
import warnings
warnings.filterwarnings('ignore')

tickers = [
    "NPN.JO", "CFR.JO", "FSR.JO", "SBK.JO", "AGL.JO", "BIL.JO", "MTN.JO", "VOD.JO", "CPI.JO", "NED.JO", 
    "ABG.JO", "SHF.JO", "SOL.JO", "PPC.JO", "IMP.JO", "AMS.JO", "SAP.JO", "WHL.JO", "MRP.JO", "TRU.JO", 
    "ARI.JO", "ANG.JO", "APN.JO", "BAT.JO", "CML.JO", "DSBP.JO", "DRD.JO", "EXX.JO", "TFG.JO", "GRT.JO", 
    "INL.JO", "JSE.JO", "KIO.JO", "TGA.JO", "MTH.JO", "AFE.JO", "AFT.JO", "OUT.JO", "TKG.JO", "SLM.JO", 
    "SSW.JO", "SPP.JO", "SHP.JO", "PIK.JO"
]

tickers = list(dict.fromkeys(tickers))

print(f"Total JSE tickers to analyze: {len(tickers)}")

results = []
failed_tickers = []

for ticker in tickers:
    try:
        stock = yf.Ticker(ticker)
        info = stock.info
        hist = stock.history(period="1y")
        
        company_name = info.get("longName", info.get("shortName", ticker.replace(".JO", "")))
        sector = info.get("sector", info.get("industry", "N/A"))
        
        if len(hist) < 126:  
            print(f"Skipping {ticker}: Insufficient historical data ({len(hist)} days)")
            failed_tickers.append(ticker)
            continue

        close = hist["Close"].dropna()
        if len(close) < 126:
            print(f"Skipping {ticker}: Insufficient valid price data ({len(close)} days)")
            failed_tickers.append(ticker)
            continue
        
        current_price = close.iloc[-1]

        if len(close) >= 21:
            ret_1m = (close.iloc[-1] / close.iloc[-21] - 1) * 100
        else:
            ret_1m = np.nan
            
        if len(close) >= 63:
            ret_3m = (close.iloc[-1] / close.iloc[-63] - 1) * 100
        else:
            ret_3m = np.nan
            
        if len(close) >= 126:
            ret_6m = (close.iloc[-1] / close.iloc[-126] - 1) * 100
        else:
            ret_6m = np.nan
        
        if len(close) >= 252:
            ret_12m = (close.iloc[-1] / close.iloc[-252] - 1) * 100
        else:
           
            ret_12m = (close.iloc[-1] / close.iloc[0] - 1) * 100

        pe = info.get("trailingPE", np.nan)
        pb = info.get("priceToBook", np.nan)
        ps = info.get("priceToSalesTrailing12Months", np.nan)
        
        market_cap = info.get("marketCap", np.nan)
        total_debt = info.get("totalDebt", np.nan)
        cash = info.get("totalCash", np.nan)
        
        enterprise_value = np.nan
        if market_cap and not np.isnan(market_cap):
            if total_debt and cash and not np.isnan(total_debt) and not np.isnan(cash):
                enterprise_value = market_cap + total_debt - cash
            elif total_debt and not np.isnan(total_debt):
                enterprise_value = market_cap + total_debt
            else:
                enterprise_value = market_cap
        
        ebit = info.get("ebitda", np.nan)  
        ev_ebit = np.nan
        if enterprise_value and not np.isnan(enterprise_value) and ebit and not np.isnan(ebit) and ebit != 0:
            ev_ebit = enterprise_value / ebit
        
        gross_profit = info.get("grossProfits", np.nan)
        ev_gp = np.nan
        if enterprise_value and not np.isnan(enterprise_value) and gross_profit and not np.isnan(gross_profit) and gross_profit != 0:
            ev_gp = enterprise_value / gross_profit
        
        ebitda = info.get("ebitda", np.nan)
        ev_ebitda = np.nan
        if enterprise_value and not np.isnan(enterprise_value) and ebitda and not np.isnan(ebitda) and ebitda != 0:
            ev_ebitda = enterprise_value / ebitda

        results.append({
            "Ticker": ticker,
            "Company": company_name,
            "Sector": sector,
            "Price": current_price / 100,
            "PE": pe,
            "PB": pb,
            "PS": ps,
            "EV_EBIT": ev_ebit,
            "EV_GP": ev_gp,
            "EV_EBITDA": ev_ebitda,
            "1M Return": ret_1m,
            "3M Return": ret_3m,
            "6M Return": ret_6m,
            "12M Return": ret_12m
        })
        
        print(f"Processed: {ticker} - {company_name[:30]} - {sector}")

    except Exception as e:
        print(f"Error processing {ticker}: {str(e)}")
        failed_tickers.append(ticker)

df = pd.DataFrame(results)

if df.empty:
    print("\nNo data collected. Exiting.")
    print(f"Failed to process {len(failed_tickers)} tickers: {failed_tickers}")
    exit()

print(f"\nSuccessfully processed {len(df)} JSE stocks")
if failed_tickers:
    print(f"Failed to process {len(failed_tickers)} tickers")

value_cols = ["PE", "PB", "PS", "EV_EBIT", "EV_GP"]

for col in value_cols:
    if col in df.columns:
      
        median_val = df[col].median()
        if not np.isnan(median_val):
            df[col] = df[col].fillna(median_val)
        else:
            df[col] = df[col].fillna(df[col].mean())
        
        df[f"{col}_Rank"] = df[col].rank(ascending=True, pct=True)
        
        df[f"{col}_Score"] = (1 - df[f"{col}_Rank"]) * 100

value_score_cols = [f"{col}_Score" for col in value_cols if f"{col}_Score" in df.columns]
df["Value_Score"] = df[value_score_cols].mean(axis=1)

momentum_cols = ["1M Return", "3M Return", "6M Return", "12M Return"]

for col in momentum_cols:
    if col in df.columns:
        
        df[col] = df[col].fillna(0)
        
        df[f"{col}_Rank"] = df[col].rank(ascending=False, pct=True)
        
        df[f"{col}_Score"] = df[f"{col}_Rank"] * 100
momentum_score_cols = [f"{col}_Score" for col in momentum_cols if f"{col}_Score" in df.columns]
df["Momentum_Score"] = df[momentum_score_cols].mean(axis=1)

df["Value_Score"] = df["Value_Score"].fillna(50)
df["Momentum_Score"] = df["Momentum_Score"].fillna(50)
df["Composite_Score"] = (0.50 * df["Value_Score"]) + (0.50 * df["Momentum_Score"])

df["Rank"] = df["Composite_Score"].rank(ascending=False).astype(int)

def get_signal(composite_score, percentile_80, percentile_60, percentile_40):
    if composite_score >= percentile_80:
        return "STRONG BUY"
    elif composite_score >= percentile_60:
        return "BUY"
    elif composite_score >= percentile_40:
        return "HOLD"
    else:
        return "SELL"

percentile_80 = df["Composite_Score"].quantile(0.80)
percentile_60 = df["Composite_Score"].quantile(0.60)
percentile_40 = df["Composite_Score"].quantile(0.40)

df["Signal"] = df["Composite_Score"].apply(
    lambda x: get_signal(x, percentile_80, percentile_60, percentile_40)
)

df = df.sort_values("Composite_Score", ascending=False).reset_index(drop=True)

for col in momentum_cols:
    if col in df.columns:
        df[col] = df[col].round(1)

for col in value_cols + ["EV_EBITDA"]:
    if col in df.columns:
        df[col] = df[col].round(1)

df["Value_Score"] = df["Value_Score"].round(1)
df["Momentum_Score"] = df["Momentum_Score"].round(1)
df["Composite_Score"] = df["Composite_Score"].round(1)

output_columns = [
    "Rank", "Ticker", "Company", "Sector", "Price", "PE", "PB", "PS", 
    "EV_EBIT", "EV_GP", "1M Return", "3M Return", "6M Return", 
    "12M Return", "Value_Score", "Momentum_Score", "Composite_Score", "Signal"
]

final_columns = [col for col in output_columns if col in df.columns]
df_output = df[final_columns].copy()
df_output["Price"] = df_output["Price"].apply(lambda x: f"R{x:.2f}")

from datetime import datetime
timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
filename = f"JSE_Stock_Rankings_{timestamp}.csv"

df_output.to_csv(filename, index=False)
print(f"Data saved to: {filename}")