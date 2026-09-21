import {ChangeDetectionStrategy, Component, Inject, OnInit, PLATFORM_ID} from '@angular/core';
import { SearchComponent } from '../search.component';
import { SearchService } from '../../../core/shared/search/search.service';
import { SidebarService } from '../../sidebar/sidebar.service';
import { HostWindowService } from '../../host-window.service';
import { SEARCH_CONFIG_SERVICE } from '../../../my-dspace-page/my-dspace-page.component';
import { SearchConfigurationService } from '../../../core/shared/search/search-configuration.service';
import { RouteService } from '../../../core/services/route.service';
import { Router } from '@angular/router';
import { pushInOut } from '../../animations/push';
import { PaginatedSearchOptions } from '../models/paginated-search-options.model';
import { isUndefined } from '../../empty.util';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { DSpaceObjectType } from '../../../core/shared/dspace-object-type.model';
import {APP_CONFIG, AppConfig} from '../../../../config/app-config.interface';

/**
 * This component was created because we customized search item boxes and they was used in the `/mydspace` as well.
 */
@Component({
  selector: 'ds-clarin-search',
  templateUrl: '../search.component.html',
  styleUrls: ['../search.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  animations: [pushInOut],
})
export class ClarinSearchComponent extends SearchComponent implements OnInit {

  constructor(protected service: SearchService,
              protected sidebarService: SidebarService,
              protected windowService: HostWindowService,
              @Inject(SEARCH_CONFIG_SERVICE) public searchConfigService: SearchConfigurationService,
              protected routeService: RouteService,
              protected router: Router,
              @Inject(APP_CONFIG) protected appConfig: AppConfig,
              @Inject(PLATFORM_ID) public platformId: any) {
    super(service, sidebarService, windowService, searchConfigService, routeService, router, appConfig, platformId);
  }

  /**
   * Delegate initialization to the current DSpace implementation. Keeping a
   * local copy here previously caused the public search page to stop rendering
   * when scope handling was added upstream.
   */
  ngOnInit(): void {
    super.ngOnInit();
  }

  /**
   * The public repository search lists deposited items. Other configurations,
   * such as MyDSpace, retain their own object type filters.
   */
  protected getSearchOptions(): Observable<PaginatedSearchOptions> {
    return super.getSearchOptions().pipe(
      map((options: PaginatedSearchOptions) => isUndefined(options.configuration)
        ? new PaginatedSearchOptions({ ...options, dsoTypes: [DSpaceObjectType.ITEM] })
        : options),
    );
  }
}
