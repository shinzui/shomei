# Run by the isolated packaged-server fixture; see README.md.

GET {{base_url}}/oauth/authorize
[Query]
client_id: {{client_id}}
response_type: code
redirect_uri: http://localhost:9999/callback
code_challenge: {{challenge}}
code_challenge_method: S256
HTTP 401
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "login_required"

POST {{base_url}}/oauth/token
[BasicAuth]
unknown: wrong
[Form]
grant_type: client_credentials
HTTP 401
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" == "Basic realm=\"shomei\""
jsonpath "$.error" == "invalid_client"

GET {{base_url}}/oauth/userinfo
HTTP 401
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" == "Bearer realm=\"shomei\""
jsonpath "$.error" == "invalid_token"

GET {{base_url}}/oauth/userinfo
Authorization: Bearer invalid-sentinel
HTTP 401
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" == "Bearer realm=\"shomei\", error=\"invalid_token\""
jsonpath "$.error" == "invalid_token"

POST {{base_url}}/oauth/token
Content-Type: application/x-www-form-urlencoded
file,oversized.form;
HTTP 413
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "invalid_request"

GET {{base_url}}/oauth/token
HTTP 405
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "invalid_request"

POST {{base_url}}/oauth/token
Accept: application/xml
Content-Type: application/x-www-form-urlencoded
HTTP 406
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "invalid_request"

POST {{base_url}}/oauth/token
Content-Type: application/xml
HTTP 415
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "invalid_request"

GET {{base_url}}/oauth/unknown
HTTP 404
Cache-Control: no-store
Pragma: no-cache
[Asserts]
header "Content-Type" startsWith "application/json"
header "WWW-Authenticate" not exists
jsonpath "$.error" == "invalid_request"

POST {{base_url}}/v1/auth/login
Content-Type: application/json
file,oversized.form;
HTTP 413
Content-Type: application/problem+json
[Asserts]
jsonpath "$.code" == "payload_too_large"
jsonpath "$.status" == 413
