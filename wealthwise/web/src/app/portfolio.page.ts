import { CurrencyPipe, DatePipe, DecimalPipe, PercentPipe } from '@angular/common';
import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink, ActivatedRoute } from '@angular/router';
import { forkJoin } from 'rxjs';
import { ApiService } from './api.service';
import { ASSET_LABEL, PortfolioDetail, RebalancePlan, Security, Trade, TradeSide } from './models';
import { DriftBarComponent } from './ui/drift-bar.component';

@Component({
  selector: 'ww-portfolio',
  imports: [FormsModule, RouterLink, CurrencyPipe, DatePipe, DecimalPipe, PercentPipe, DriftBarComponent],
  template: `
    <a class="back" routerLink="/">All portfolios</a>

    @if (error()) { <p class="banner err" role="alert">{{ error() }}</p> }

    @if (detail(); as d) {
      <header class="page-head">
        <h1>{{ d.name }}</h1>
        <p class="muted">{{ d.clientName }} · {{ d.riskProfile }} mandate</p>
        <p class="total num">{{ d.valuation.totalValue | currency: 'USD' : 'symbol' : '1.0-0' }}</p>
        <p class="facts">
          <span>Cash <b class="num">{{ d.valuation.cash | currency: 'USD' : 'symbol' : '1.0-0' }}</b></span>
          <span>Cost basis <b class="num">{{ d.valuation.totalCost | currency: 'USD' : 'symbol' : '1.0-0' }}</b></span>
          <span>Unrealized
            <b class="num" [class.gain]="d.valuation.unrealizedGain >= 0" [class.loss]="d.valuation.unrealizedGain < 0">
              {{ d.valuation.unrealizedGain | currency: 'USD' : 'symbol' : '1.0-0' }}
            </b>
          </span>
        </p>
      </header>

      <div class="cols">
        <div class="col-main">
          <section>
            <h2>Allocation against target</h2>
            <ww-drift-bar [lines]="d.valuation.allocation" [projected]="plan()?.projectedAllocation ?? null" [band]="bandFraction()" />
            <p class="legend muted small">
              The tick marks the target. @if (plan()) { The ring shows where each class lands after the proposed trades. }
              Rows turn red when drift exceeds {{ bandFraction() | percent: '1.0-1' }}.
            </p>
          </section>

          <section>
            <h2>Holdings</h2>
            <div class="scroll">
              <table class="grid">
                <thead><tr><th>Security</th><th>Class</th><th class="r">Qty</th><th class="r">Price</th><th class="r">Value</th><th class="r">Gain</th></tr></thead>
                <tbody>
                  @for (h of d.valuation.holdings; track h.symbol) {
                    <tr>
                      <td><b>{{ h.symbol }}</b><div class="muted small">{{ h.name }}</div></td>
                      <td>{{ label(h.assetClass) }}</td>
                      <td class="r num">{{ h.quantity | number: '1.0-4' }}</td>
                      <td class="r num">{{ h.price | currency: 'USD' }}</td>
                      <td class="r num">{{ h.marketValue | currency: 'USD' : 'symbol' : '1.0-0' }}</td>
                      <td class="r num" [class.gain]="h.unrealizedGain >= 0" [class.loss]="h.unrealizedGain < 0">
                        {{ h.unrealizedGain | currency: 'USD' : 'symbol' : '1.0-0' }}
                      </td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          </section>

          <section>
            <h2>Recent trades</h2>
            <div class="scroll">
              <table class="grid">
                <thead><tr><th>When</th><th>Order</th><th class="r">Price</th><th class="r">Notional</th></tr></thead>
                <tbody>
                  @for (t of trades(); track t.id) {
                    <tr>
                      <td class="num">{{ t.executedAt | date: 'MMM d, y HH:mm' }}</td>
                      <td>{{ t.side }} {{ t.quantity | number: '1.0-4' }} {{ t.symbol }}</td>
                      <td class="r num">{{ t.price | currency: 'USD' }}</td>
                      <td class="r num">{{ t.notional | currency: 'USD' : 'symbol' : '1.0-0' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          </section>
        </div>

        <aside class="col-side">
          <section class="panel">
            <h2>Rebalance</h2>
            <div class="field">
              <label for="strategy">Strategy</label>
              <select id="strategy" [(ngModel)]="strategy">
                <option value="threshold">Threshold: trade only outside the band</option>
                <option value="full">Full: return everything to target</option>
              </select>
            </div>
            @if (strategy === 'threshold') {
              <div class="field">
                <label for="band">Band (percentage points)</label>
                <input id="band" type="number" min="1" max="25" step="0.5" [(ngModel)]="bandPct">
              </div>
            }
            <button class="btn" (click)="propose()" [disabled]="busy()">Propose trades</button>

            @if (plan(); as p) {
              @if (p.trades.length === 0) {
                <p class="muted">Nothing to do: every class is inside the band.</p>
              } @else {
                <ul class="plan">
                  @for (t of p.trades; track t.assetClass) {
                    <li>
                      <span [class.gain]="t.side === 'Buy'" [class.loss]="t.side === 'Sell'">{{ t.side }}</span>
                      {{ label(t.assetClass) }}
                      <b class="num">{{ t.amount | currency: 'USD' : 'symbol' : '1.0-0' }}</b>
                    </li>
                  }
                </ul>
                <p class="muted small">Cash afterwards: <span class="num">{{ p.cashAfter | currency: 'USD' : 'symbol' : '1.0-0' }}</span></p>
              }
            }
          </section>

          <section class="panel">
            <h2>Trade ticket</h2>
            <form (ngSubmit)="submit()" #f="ngForm">
              <div class="field">
                <label for="symbol">Security</label>
                <select id="symbol" name="symbol" [(ngModel)]="ticket.symbol" required>
                  @for (s of securities(); track s.symbol) { <option [value]="s.symbol">{{ s.symbol }} · {{ s.name }}</option> }
                </select>
              </div>
              <fieldset class="field seg">
                <legend>Side</legend>
                <label><input type="radio" name="side" value="Buy" [(ngModel)]="ticket.side"> Buy</label>
                <label><input type="radio" name="side" value="Sell" [(ngModel)]="ticket.side"> Sell</label>
              </fieldset>
              <div class="field">
                <label for="qty">Quantity</label>
                <input id="qty" name="qty" type="number" min="0.0001" step="any" [(ngModel)]="ticket.quantity" required>
              </div>
              <button class="btn primary" type="submit" [disabled]="busy() || f.invalid">Execute at market</button>
            </form>
            @if (notice()) { <p class="banner ok" role="status">{{ notice() }}</p> }
          </section>
        </aside>
      </div>
    }
  `
})
export class PortfolioPage implements OnInit, OnDestroy {
  private api = inject(ApiService);
  private route = inject(ActivatedRoute);
  private id = '';
  private refreshTimer?: number;

  detail = signal<PortfolioDetail | null>(null);
  trades = signal<Trade[]>([]);
  securities = signal<Security[]>([]);
  plan = signal<RebalancePlan | null>(null);
  error = signal<string | null>(null);
  notice = signal<string | null>(null);
  busy = signal(false);

  strategy: 'threshold' | 'full' = 'threshold';
  bandPct = 5;
  ticket: { symbol: string; side: TradeSide; quantity: number } = { symbol: 'VTI', side: 'Buy', quantity: 10 };

  bandFraction() { return this.strategy === 'threshold' ? this.bandPct / 100 : 0.05; }
  label(c: keyof typeof ASSET_LABEL) { return ASSET_LABEL[c]; }

  ngOnInit() {
    this.id = this.route.snapshot.paramMap.get('id') ?? '';
    forkJoin({ d: this.api.portfolio(this.id), t: this.api.trades(this.id), s: this.api.securities() }).subscribe({
      next: ({ d, t, s }) => { this.detail.set(d); this.trades.set(t); this.securities.set(s); },
      error: e => this.error.set(ApiService.message(e))
    });
    // Quotes move, so revalue periodically.
    this.refreshTimer = window.setInterval(() => this.refreshValuation(), 15_000);
  }

  ngOnDestroy() { window.clearInterval(this.refreshTimer); }

  private refreshValuation() {
    this.api.portfolio(this.id).subscribe({ next: d => this.detail.set(d), error: () => { /* keep last good view */ } });
  }

  propose() {
    this.busy.set(true);
    this.error.set(null);
    this.api.rebalance(this.id, this.strategy, this.bandFraction()).subscribe({
      next: p => { this.plan.set(p); this.busy.set(false); },
      error: e => { this.error.set(ApiService.message(e)); this.busy.set(false); }
    });
  }

  submit() {
    this.busy.set(true);
    this.error.set(null);
    this.notice.set(null);
    const { symbol, side, quantity } = this.ticket;
    this.api.placeTrade(this.id, symbol, side, Number(quantity)).subscribe({
      next: t => {
        this.notice.set(`${t.side} ${t.quantity} ${t.symbol} filled at ${t.price.toFixed(2)}.`);
        this.plan.set(null);
        this.busy.set(false);
        forkJoin({ d: this.api.portfolio(this.id), t: this.api.trades(this.id) })
          .subscribe(({ d, t }) => { this.detail.set(d); this.trades.set(t); });
      },
      error: e => { this.error.set(ApiService.message(e)); this.busy.set(false); }
    });
  }
}
