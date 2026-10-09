import { ChangeDetectorRef, Component, Inject, OnDestroy, OnInit } from '@angular/core';
import { HtmlContentService } from '../shared/html-content.service';
import { BehaviorSubject, Subscription } from 'rxjs';
import { NavigationEnd, Router } from '@angular/router';
import { filter } from 'rxjs/operators';
import { isEmpty } from '../shared/empty.util';
import { STATIC_PAGE_PATH } from './static-page-routing-paths';
import { APP_CONFIG, AppConfig } from '../../config/app-config.interface';
import { ServerResponseService } from '../core/services/server-response.service';

/**
 * Component which load and show static files from the `static-files` folder.
 * E.g., `<UI_URL>/static/test_file.html will load the file content from the `static-files/test_file.html`/
 */
@Component({
  selector: 'ds-static-page',
  templateUrl: './static-page.component.html',
  styleUrls: ['./static-page.component.scss']
})
export class StaticPageComponent implements OnInit, OnDestroy {
  htmlContent: BehaviorSubject<string> = new BehaviorSubject<string>('');
  htmlFileName: string;
  contentState: 'loading' | 'found' | 'not-found' = 'loading';
  private routerEventsSubscription: Subscription;
  private loadSequence = 0;

  constructor(private htmlContentService: HtmlContentService,
              private router: Router,
              private responseService: ServerResponseService,
              private changeDetector: ChangeDetectorRef,
              @Inject(APP_CONFIG) protected appConfig?: AppConfig) { }

  async ngOnInit(): Promise<void> {
    this.routerEventsSubscription = this.router.events.pipe(
      filter((event): event is NavigationEnd => event instanceof NavigationEnd)
    ).subscribe(() => {
      void this.loadCurrentPage();
    });

    await this.loadCurrentPage(true);
  }

  ngOnDestroy(): void {
    this.routerEventsSubscription?.unsubscribe();
  }

  /**
   * Load the static file selected by the current route. Angular reuses this
   * component when only `:htmlFileName` changes, so NavigationEnd events must
   * trigger a fresh load. The sequence token prevents a slower previous
   * request from replacing the content of a newer route.
   */
  private async loadCurrentPage(force = false): Promise<void> {
    const requestedFileName = this.getHtmlFileName();
    if (!force && requestedFileName === this.htmlFileName) {
      return;
    }

    const loadSequence = ++this.loadSequence;
    this.htmlFileName = requestedFileName;

    try {
      this.contentState = 'loading';
      this.htmlContent.next('');

      let htmlContent = await this.htmlContentService.getHmtlContentByPathAndLocale(this.htmlFileName);
      if (loadSequence !== this.loadSequence) {
        return;
      }

      if (htmlContent !== undefined) {
        const restBase = this.appConfig?.rest?.baseUrl;
        const oaiUrl = restBase ? restBase.replace(/\/+$/, '') + '/oai' : '/server/oai';
        htmlContent = htmlContent.replace(/href="\/server\/oai/gi, 'href="' + oaiUrl);
        // Keep editorial links inside the UI namespace, while leaving API and federation paths intact.
        const namespacePrefix = this.getNamespacePrefix();
        if (namespacePrefix) {
          htmlContent = htmlContent.replace(
            /href="\/(?!\/|server(?:\/|")|oai(?:\/|")|shibboleth(?:\/|")|dspace(?:\/|"))/gi,
            `href="${namespacePrefix}/`
          );
        }

        // Fragment-only links resolve against the document's <base> element,
        // even before Angular handles clicks. Give them the current public
        // page URL so they also work during SSR and when opened in a new tab.
        const currentPageUrl = this.getPublicPageUrl().replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        htmlContent = htmlContent.replace(
          /href="#([^"]+)"/gi,
          (_match, fragment) => `href="${currentPageUrl}#${fragment}"`
        );

        this.htmlContent.next(htmlContent);
        this.contentState = 'found';
        this.changeDetector.detectChanges();
        return;
      }

      // Content not found - set 404 status for SSR and show inline error
      this.responseService.setNotFound();
      this.contentState = 'not-found';
      this.changeDetector.detectChanges();
    } catch (error) {
      if (loadSequence !== this.loadSequence) {
        return;
      }

      console.error('Static page load error:', {
        fileName: this.htmlFileName,
        url: this.router.url,
        error: error
      });
      this.responseService.setNotFound();
      this.contentState = 'not-found';
      this.changeDetector.detectChanges();
    }
  }

  /**
   * Handle click on links in the static page.
   * @param event
   */
  processLinks(event: Event): void {
    const targetElement = event.target as HTMLElement | null;
    const anchorElement = targetElement?.closest?.('a');
    if (!anchorElement) {
      return;
    }

    const href = anchorElement.getAttribute('href');
    if (!href) {
      return;
    }

    // A fragment-only href resolves against <base href="/dspace/"> instead
    // of the current static page. Keep the page path when navigating to its
    // sections so Angular's anchor scrolling can find the target heading.
    if (href.startsWith('#')) {
      event.preventDefault();
      void this.router.navigateByUrl(`${this.router.url.split('#')[0]}${href}`);
      return;
    }

    if (!this.isRelativeLink(href)) {
      return;
    }

    event.preventDefault();
    void this.router.navigateByUrl(this.composeRelativeRouterUrl(href));
  }

  private getNamespacePrefix(): string {
    const nameSpace = this.appConfig?.ui?.nameSpace ?? '/';
    return nameSpace === '/' ? '' : nameSpace.replace(/\/$/, '');
  }

  private getPublicPageUrl(): string {
    const routeUrl = this.router.url.split('#')[0];
    const namespacePrefix = this.getNamespacePrefix();
    const alreadyNamespaced = routeUrl === namespacePrefix ||
      routeUrl.startsWith(`${namespacePrefix}/`) || routeUrl.startsWith(`${namespacePrefix}?`);
    return namespacePrefix && !alreadyNamespaced ? `${namespacePrefix}${routeUrl}` : routeUrl;
  }

  private isRelativeLink(href: string | null): boolean {
    return href?.startsWith('.') ?? false;
  }

  private composeRelativeRouterUrl(href: string): string {
    const staticRouteBase = new URL(`/${STATIC_PAGE_PATH}/`, window.location.origin);
    const target = new URL(href, staticRouteBase);
    return `${target.pathname}${target.search}${target.hash}`;
  }

  /**
   * Load file name from the URL - `static/FILE_NAME.html`
   * @private
   */
  private getHtmlFileName() {
    const routePath = this.router.url?.split(/[?#]/, 1)[0] ?? '';
    const routeSegments = routePath.split('/').filter(segment => segment);
    const staticPageSegment = routeSegments.indexOf(STATIC_PAGE_PATH);

    // Locate the route by name instead of by a fixed array position. Production
    // runs below /dspace, so its URL is /dspace/static/<page> while local and
    // test installations may use /static/<page>.
    if (isEmpty(routeSegments) || staticPageSegment < 0 || !routeSegments[staticPageSegment + 1]) {
      return null;
    }

    return routeSegments[staticPageSegment + 1];
  }
}
