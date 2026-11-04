export type AssetClass = 'Equity' | 'FixedIncome' | 'Cash' | 'Alternatives';
export type RiskProfile = 'Conservative' | 'Balanced' | 'Growth';
export type TradeSide = 'Buy' | 'Sell';

export interface PortfolioSummary {
  id: string; name: string; clientName: string; riskProfile: RiskProfile;
  totalValue: number; unrealizedGain: number; maxDrift: number;
}
export interface HoldingValuation {
  symbol: string; name: string; assetClass: AssetClass; quantity: number; price: number;
  marketValue: number; costBasis: number; unrealizedGain: number;
}
export interface AllocationLine { assetClass: AssetClass; value: number; actual: number; target: number; drift: number; }
export interface PortfolioValuation {
  totalValue: number; cash: number; totalCost: number; unrealizedGain: number;
  holdings: HoldingValuation[]; allocation: AllocationLine[];
}
export interface PortfolioDetail {
  id: string; name: string; clientName: string; riskProfile: RiskProfile; valuation: PortfolioValuation;
}
export interface ProposedTrade { assetClass: AssetClass; side: TradeSide; amount: number; reason: string; }
export interface RebalancePlan {
  strategy: string; totalValue: number; trades: ProposedTrade[]; cashAfter: number; projectedAllocation: AllocationLine[];
}
export interface Trade {
  id: string; symbol: string; side: TradeSide; quantity: number; price: number; notional: number; executedAt: string;
}
export interface Security { symbol: string; name: string; assetClass: AssetClass; basePrice: number; }
export interface AuditEntry { eventId: string; type: string; at: string; payload: { portfolioId?: string; trade?: Trade }; }

export const ASSET_LABEL: Record<AssetClass, string> = {
  Equity: 'Equities', FixedIncome: 'Fixed income', Cash: 'Cash', Alternatives: 'Alternatives'
};
