import { Component, Input, OnChanges, OnDestroy, OnInit, SimpleChanges } from '@angular/core';
import { Item } from '../../core/shared/item.model';
import { getFirstSucceededRemoteDataPayload } from '../../core/shared/operators';
import { getItemPageRoute } from '../item-page-routing-paths';
import { MetadataBitstream } from '../../core/metadata/metadata-bitstream.model';
import { RegistryService } from '../../core/registry/registry.service';
import { Router } from '@angular/router';
import { HALEndpointService } from '../../core/shared/hal-endpoint.service';
import { ConfigurationDataService } from '../../core/data/configuration-data.service';
import { BehaviorSubject, Subscription } from 'rxjs';
import { NgbModal } from '@ng-bootstrap/ng-bootstrap';

@Component({
  selector: 'ds-clarin-files-section',
  templateUrl: './clarin-files-section.component.html',
  styleUrls: ['./clarin-files-section.component.scss']
})
export class ClarinFilesSectionComponent implements OnInit, OnChanges, OnDestroy {

  /**
   * The item to display files for
   */
  @Input() item: Item;

  /**
   * handle of the current item
   */
  @Input() itemHandle: string;

  canShowCurlDownload = false;

  /**
   * Whether the command was recently copied to clipboard
   */
  commandCopied = false;

  /**
   * command for the download command feature
   */
  command: string;

  /**
   * determine to show download all zip button or not
   */
  canDownloadAllFiles = false;
  totalFileCount = 0;

  /**
   * total size of list of files uploaded by users to this item
   */
  totalFileSizes: BehaviorSubject<number> = new BehaviorSubject<number>(-1);

  /**
   * list of files uploaded by users to this item
   */
  listOfFiles: BehaviorSubject<MetadataBitstream[]> = new BehaviorSubject<MetadataBitstream[]>([]);

  /**
   * min file size to show `Download all ZIP` button, this value is loaded from the configuration property
   * `download.all.alert.min.file.size`
   */
  downloadZipMinFileSize: BehaviorSubject<number> = new BehaviorSubject<number>(-1);

  /**
   * max file size to show `Download all ZIP` button, this value is loaded from the configuration property
   * `download.all.limit.max.file.size`
   */
  downloadZipMaxFileSize: BehaviorSubject<number> = new BehaviorSubject<number>(-1);

  /**
   * min count of files to show `Download all ZIP` button, this value is loaded from the configuration property
   * `download.all.limit.min.file.count`
   */
  downloadZipMinFileCount: BehaviorSubject<number> = new BehaviorSubject<number>(-1);

  private currentItemHandle: string;
  private filesSubscription?: Subscription;


  constructor(protected registryService: RegistryService,
              protected router: Router,
              protected halService: HALEndpointService,
              protected configurationService: ConfigurationDataService,
              protected modalService: NgbModal) {
  }

  ngOnInit(): void {
    this.loadDownloadZipConfigProperties();
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes.item || changes.itemHandle) {
      this.refreshFromInputs(true);
    }
  }

  ngOnDestroy(): void {
    this.filesSubscription?.unsubscribe();
  }

  openCommandModal(content: any) {
    this.commandCopied = false;
    this.modalService.open(content, { size: 'lg', centered: true, ariaLabelledBy: 'commandModalTitle' });
  }

  copyCommand() {
    navigator.clipboard.writeText(this.command).then(() => {
      this.commandCopied = true;
      setTimeout(() => this.commandCopied = false, 2000);
    }).catch(() => {
      // Fallback: clipboard API may be unavailable (non-HTTPS, denied permissions)
      this.commandCopied = false;
    });
  }

  downloadFiles() {
    void this.router.navigate([getItemPageRoute(this.item), 'download', 'zip']);
  }

  generateCurlCommand() {
    this.canShowCurlDownload = this.totalFileCount > 0;
    const handle = this.currentItemHandle;
    const url = `${this.halService.getRootHref()}/core/items/${this.item.uuid}/allzip?handleId=${encodeURIComponent(handle)}`;
    const quote = (value: string) => "'" + value.replace(/'/g, "'\\''") + "'";
    this.command = `curl --fail --location --output ${quote(handle.replace('/', '-') + '.zip')} ${quote(url)}`;
  }

  loadDownloadZipConfigProperties() {
    this.configurationService.findByPropertyName('download.all.limit.min.file.count')
      .pipe(
        getFirstSucceededRemoteDataPayload()
      )
      .subscribe((config) => {
        this.downloadZipMinFileCount.next(Number(config.values[0]));
      });

    this.configurationService.findByPropertyName('download.all.limit.max.file.size')
      .pipe(
        getFirstSucceededRemoteDataPayload()
      )
      .subscribe((config) => {
        this.downloadZipMaxFileSize.next(Number(config.values[0]));
      });

    this.configurationService.findByPropertyName('download.all.alert.min.file.size')
      .pipe(
        getFirstSucceededRemoteDataPayload()
      )
      .subscribe((config) => {
        this.downloadZipMinFileSize.next(Number(config.values[0]));
      });
  }

  private refreshFromInputs(force = false): void {
    if (this.item) {
      this.totalFileSizes.next(Number(this.item.firstMetadataValue('local.files.size')));
    }

    const handle = this.itemHandle || this.item?.handle;
    if (!handle) {
      return;
    }

    if (!force && handle === this.currentItemHandle) {
      return;
    }

    this.currentItemHandle = handle;
    this.totalFileCount = 0;
    this.canShowCurlDownload = false;
    this.filesSubscription?.unsubscribe();
    this.filesSubscription = this.registryService
      .getMetadataBitstream(handle, 'ORIGINAL', { currentPage: 1, elementsPerPage: 1 })
      .pipe(getFirstSucceededRemoteDataPayload())
      .subscribe((data) => {
        this.listOfFiles.next(data.page || []);
        this.totalFileCount = data.totalElements;
        this.generateCurlCommand();
      });
  }
}
