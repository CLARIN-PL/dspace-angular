import { ObjectCacheService } from '../cache/object-cache.service';
import { RawRestResponse } from '../dspace-rest/raw-rest-response.model';
import { DspaceRestResponseParsingService } from './dspace-rest-response-parsing.service';
import { GetRequest } from './request.models';
import { RestRequest } from './rest-request.model';

class TestService extends DspaceRestResponseParsingService {
  public normalizeSelfLink(request: RestRequest, response: RawRestResponse): RawRestResponse {
    return this.ensureSelfLink(request, response);
  }
}

describe('DspaceRestResponseParsingService', () => {
  let service: TestService;
  let consoleWarn: jasmine.Spy;

  beforeEach(() => {
    service = new TestService(jasmine.createSpyObj<ObjectCacheService>('objectCache', ['add']));
    consoleWarn = spyOn(console, 'warn');
  });

  function responseWithSelfLink(href: string): RawRestResponse {
    return {
      payload: { _links: { self: { href } } },
      statusCode: 200,
      statusText: 'OK'
    };
  }

  it('silently normalizes query-only self-link differences to the requested URL', () => {
    const requestedHref = 'https://repository.example/server/api/discover/search/objects?configuration=workspace&size=20';
    const response = responseWithSelfLink('https://repository.example/server/api/discover/search/objects?size=20');

    const result = service.normalizeSelfLink(new GetRequest('request-id', requestedHref), response);

    expect(result.payload._links.self.href).toBe(requestedHref);
    expect(consoleWarn).not.toHaveBeenCalled();
  });

  it('preserves the canonical self link when a relationship response points to another endpoint', () => {
    const requestedHref = 'https://repository.example/server/api/core/items';
    const response = responseWithSelfLink('https://repository.example/server/api/core/collections');

    const result = service.normalizeSelfLink(new GetRequest('request-id', requestedHref), response);

    expect(result.payload._links.self.href).toBe('https://repository.example/server/api/core/collections');
    expect(consoleWarn).not.toHaveBeenCalled();
  });
});
