import { PercentPipe } from '@angular/common';
import { Component, input } from '@angular/core';
import { ASSET_LABEL, AllocationLine } from '../models';

/**
 * One row per asset class. The fill is today's weight, the vertical tick is the target, and the
 * ring (when a rebalance is proposed) shows where the weight would land after trading.
 */
@Component({
  selector: 'ww-drift-bar',
  imports: [PercentPipe],
  template: `
    <div class="drift">
      @for (a of lines(); track a.assetClass) {
        <div class="drift-row" [class.out]="outside(a)">
          <span class="drift-label">{{ label(a) }}</span>
          <div class="drift-track" role="img"
               [attr.aria-label]="label(a) + ' is ' + (a.actual * 100).toFixed(1) + ' percent, target ' + (a.target * 100).toFixed(1) + ' percent'">
            <div class="drift-fill" [style.width.%]="a.actual * 100"></div>
            <div class="drift-target" [style.left.%]="a.target * 100"></div>
            @if (after(a); as p) {
              <div class="drift-after" [style.left.%]="p.actual * 100"></div>
            }
          </div>
          <span class="drift-num num">
            {{ a.actual | percent: '1.1-1' }}
            <small>of {{ a.target | percent: '1.0-1' }}</small>
          </span>
        </div>
      }
    </div>
  `
})
export class DriftBarComponent {
  lines = input.required<AllocationLine[]>();
  projected = input<AllocationLine[] | null>(null);
  band = input(0.05);

  label(a: AllocationLine) { return ASSET_LABEL[a.assetClass]; }
  outside(a: AllocationLine) { return Math.abs(a.drift) > this.band(); }
  after(a: AllocationLine) { return this.projected()?.find(p => p.assetClass === a.assetClass) ?? null; }
}
