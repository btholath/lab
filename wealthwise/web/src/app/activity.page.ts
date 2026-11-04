import { CurrencyPipe, DatePipe } from '@angular/common';
import { Component, OnInit, inject, signal } from '@angular/core';
import { ApiService } from './api.service';
import { AuditEntry } from './models';

@Component({
  selector: 'ww-activity',
  imports: [DatePipe, CurrencyPipe],
  template: `
    <header class="page-head">
      <h1>Activity</h1>
      <p class="muted">Trade events as they arrive through the queue. Each row was published by the API, consumed by the worker and written once, even if delivered twice.</p>
    </header>
    @if (error()) { <p class="banner err" role="alert">{{ error() }}</p> }
    <table class="grid">
      <thead><tr><th>Received</th><th>Event</th><th>Order</th><th class="r">Notional</th></tr></thead>
      <tbody>
        @for (e of entries(); track e.eventId) {
          <tr>
            <td class="num">{{ e.at | date: 'MMM d, HH:mm:ss' }}</td>
            <td>{{ e.type }}</td>
            <td>{{ e.payload.trade?.side }} {{ e.payload.trade?.quantity }} {{ e.payload.trade?.symbol }}</td>
            <td class="r num">{{ e.payload.trade?.notional | currency: 'USD' }}</td>
          </tr>
        } @empty {
          <tr><td colspan="4" class="muted">No events yet. Place a trade from a portfolio page.</td></tr>
        }
      </tbody>
    </table>
    <button class="btn quiet" (click)="load()">Refresh</button>
  `
})
export class ActivityPage implements OnInit {
  private api = inject(ApiService);
  entries = signal<AuditEntry[]>([]);
  error = signal<string | null>(null);

  ngOnInit() { this.load(); }
  load() {
    this.api.audit().subscribe({ next: e => this.entries.set(e), error: e => this.error.set(ApiService.message(e)) });
  }
}
