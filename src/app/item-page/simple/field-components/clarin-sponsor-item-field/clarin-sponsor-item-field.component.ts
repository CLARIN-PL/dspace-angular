import { Component, Input } from '@angular/core';
import { Item } from '../../../../core/shared/item.model';
import { SEPARATOR } from '../../../../shared/form/builder/ds-dynamic-form-ui/models/ds-dynamic-complex.model';


@Component({
  selector: 'ds-clarin-sponsor-item-field',
  templateUrl: './clarin-sponsor-item-field.component.html',
  styleUrls: ['./clarin-sponsor-item-field.component.scss']
})
export class ClarinSponsorItemFieldComponent {

  @Input() item: Item;

  SPONSOR_VALUE_SEPARATOR = SEPARATOR;

  hasDisplayValue(value: string): boolean {
    const normalized = value?.trim();
    // Legacy deposits may use N/A where no project number was provided.
    return !!normalized && !/^(?:n\/a|n\.a\.?|na|not available)$/i.test(normalized);
  }
}
