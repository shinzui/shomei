# Separate server lifetime with one token and a negligible refill rate.
POST {{base_url}}/oauth/token
[Form]
grant_type: client_credentials
HTTP 401
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
jsonpath "$.error" == "invalid_client"

POST {{base_url}}/oauth/token
[Form]
grant_type: client_credentials
HTTP 429
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
header "Retry-After" == "60"
jsonpath "$.error" == "temporarily_unavailable"
