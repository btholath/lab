import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import {
  AuditEntry, PortfolioDetail, PortfolioSummary, RebalancePlan, Security, Trade, TradeSide
} from './models';

@Injectable({ providedIn: 'root' })
export class ApiService {
  private http = inject(HttpClient);
  private base = '/api';

  portfolios(): Observable<PortfolioSummary[]> { return this.http.get<PortfolioSummary[]>(`${this.base}/portfolios`); }
  portfolio(id: string): Observable<PortfolioDetail> { return this.http.get<PortfolioDetail>(`${this.base}/portfolios/${id}`); }
  trades(id: string): Observable<Trade[]> { return this.http.get<Trade[]>(`${this.base}/portfolios/${id}/trades?take=15`); }
  securities(): Observable<Security[]> { return this.http.get<Security[]>(`${this.base}/securities`); }
  audit(): Observable<AuditEntry[]> { return this.http.get<AuditEntry[]>(`${this.base}/audit?take=40`); }

  rebalance(id: string, strategy: string, band: number): Observable<RebalancePlan> {
    return this.http.get<RebalancePlan>(`${this.base}/portfolios/${id}/rebalance`, { params: { strategy, band } });
  }
  placeTrade(id: string, symbol: string, side: TradeSide, quantity: number): Observable<Trade> {
    return this.http.post<Trade>(`${this.base}/portfolios/${id}/trades`, { symbol, side, quantity });
  }

  /** Pull a human-readable message out of an RFC 7807 problem response. */
  static message(err: unknown): string {
    if (err instanceof HttpErrorResponse) {
      if (err.status === 0) return 'The API is unreachable. Is the stack running?';
      if (err.status === 401) return 'The gateway rejected the API key.';
      if (err.status === 429) return 'Rate limit reached at the gateway. Try again in a moment.';
      return err.error?.detail ?? err.error?.title ?? `Request failed (${err.status}).`;
    }
    return 'Something went wrong.';
  }
}
