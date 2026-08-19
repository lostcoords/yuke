/*
The Model and Provider types the daemon runs on, plus the decoder that normalizes
selected models.dev records into them. No lifecycle, network, or persistence state.

The feed is syntax-checked without allocating, then scanned token by token; only
provider subtrees the caller named are materialized. Returned values are owned by the
caller allocator and released together by result_destroy.

models.dev is routing input, not protocol authority: a closed package and shape mapping
picks one of yuke's wire protocols, every resolved base URL passes endpoint_validate,
and no unknown package, header, or body overlay reaches transport behavior.
*/

package catalog
