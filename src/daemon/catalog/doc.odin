/*
The catalog package decodes and normalizes selected models.dev provider records.
It has no daemon lifecycle, network, persistence, credential, or broadcast state.

The complete response is syntax-checked without allocations, then its root object
is scanned token by token. Only provider subtrees named by the caller are
materialized, and those trees live in a temporary arena. Returned Provider,
Model, and Issue values are owned by the caller allocator and released together
with result_destroy.

models.dev is routing input rather than protocol authority. A closed package and
shape mapping selects one of Yuke's existing wire protocols, and every resolved
base URL passes provider.endpoint_validate before it is retained. Models with
unsupported modalities or route packages are filtered; malformed selected
provider data is reported without replacing that provider's previous snapshot.
No unknown package, request header, or request-body overlay is inferred into
transport behavior.
*/

package catalog
