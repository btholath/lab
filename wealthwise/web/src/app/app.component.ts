import { Component } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

@Component({
  selector: 'ww-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive],
  template: `
    <div class="shell">
      <nav class="rail" aria-label="Primary">
        <a class="brand" routerLink="/">WealthWise</a>
        <a routerLink="/" routerLinkActive="active" [routerLinkActiveOptions]="{ exact: true }">Portfolios</a>
        <a routerLink="/activity" routerLinkActive="active">Activity</a>
        <p class="rail-note">Demo data and simulated prices. Not investment advice.</p>
      </nav>
      <main class="main"><router-outlet /></main>
    </div>
  `
})
export class AppComponent {}
