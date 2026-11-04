import { CurrencyPipe, PercentPipe } from '@angular/common';
import { Component, OnInit, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { ApiService } from './api.service';
import { PortfolioSummary } from './models';

@Component({
  selector: 'ww-portfolios',
  imports: [RouterLink, CurrencyPipe, PercentPipe],
  template: `
    <header class="page-head">
      <h1>Portfolios</h1>
      <p class="muted">{{ items().length }} accounts under advice. Drift is the largest gap between any asset class and its target.</p>
    </header>

    @if (error()) { <p class="banner err" role="alert">{{ error() }}</p> }

    <table class="grid">
      <thead>
        <tr><th>Account</th><th>Risk profile</th><th class="r">Value</th><th class="r">Unrealized</th><th class="r">Largest drift</th></tr>
      </thead>
      <tbody>
        @for (p of items(); track p.id) {
          <tr>
            <td><a class="rowlink" [routerLink]="['/portfolios', p.id]">{{ p.name }}</a><div class="muted small">{{ p.clientName }}</div></td>
            <td>{{ p.riskProfile }}</td>
            <td class="r num">{{ p.totalValue | currency: 'USD' : 'symbol' : '1.0-0' }}</td>
            <td class="r num" [class.gain]="p.unrealizedGain >= 0" [class.loss]="p.unrealizedGain < 0">
              {{ p.unrealizedGain | currency: 'USD' : 'symbol' : '1.0-0' }}
            </td>
            <td class="r num">
              <span class="pill" [class.warn]="p.maxDrift > 0.05">{{ p.maxDrift | percent: '1.1-1' }}</span>
            </td>
          </tr>
        } @empty {
          @if (!error()) { <tr><td colspan="5" class="muted">Loading…</td></tr> }
        }
      </tbody>
    </table>
  `
})
export class PortfoliosPage implements OnInit {
  private api = inject(ApiService);
  items = signal<PortfolioSummary[]>([]);
  error = signal<string | null>(null);

  ngOnInit() {
    this.api.portfolios().subscribe({
      next: p => this.items.set(p),
      error: e => this.error.set(ApiService.message(e))
    });
  }
}
