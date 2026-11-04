import { Routes } from '@angular/router';

export const routes: Routes = [
  { path: '', pathMatch: 'full', loadComponent: () => import('./portfolios.page').then(m => m.PortfoliosPage), title: 'Portfolios · WealthWise' },
  { path: 'portfolios/:id', loadComponent: () => import('./portfolio.page').then(m => m.PortfolioPage), title: 'Portfolio · WealthWise' },
  { path: 'activity', loadComponent: () => import('./activity.page').then(m => m.ActivityPage), title: 'Activity · WealthWise' },
  { path: '**', redirectTo: '' }
];
