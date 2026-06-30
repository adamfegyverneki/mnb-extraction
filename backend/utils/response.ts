/**
 * Create a standardized API Gateway response
 */
export interface ApiGatewayResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

export interface CookieOptions {
  maxAge?: number;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: 'Strict' | 'Lax' | 'None';
  path?: string;
}

function createResponse(statusCode: number, body: any, headers: Record<string, string> = {}): ApiGatewayResponse {
  // Use specific origin when set (prod deploy) so credentials work; * for local dev
  const allowOrigin = process.env.CORS_ORIGIN || '*';
  const defaultHeaders: Record<string, string> = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-POSTHOG-DISTINCT-ID, X-POSTHOG-SESSION-ID',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Credentials': 'true'
  };

  return {
    statusCode,
    headers: {
      ...defaultHeaders,
      ...headers
    },
    body: JSON.stringify(body)
  };
}

/**
 * Create success response
 */
export function success(body: any, statusCode: number = 200): ApiGatewayResponse {
  return createResponse(statusCode, body);
}

/**
 * Create error response
 */
export function error(message: string, statusCode: number = 500): ApiGatewayResponse {
  return createResponse(statusCode, { error: message });
}

/**
 * Set cookie in response headers
 * @param name - Cookie name
 * @param value - Cookie value
 * @param options - Cookie options
 * @returns Set-Cookie header value
 */
export function setCookie(name: string, value: string, options: CookieOptions = {}): string {
  const {
    maxAge = 604800, // 7 days default
    httpOnly = true,
    secure = process.env.NODE_ENV === 'production',
    sameSite = 'Lax',
    path = '/'
  } = options;

  // JWT tokens are base64url encoded (URL-safe base64) and don't need encoding
  // However, serverless-offline's @hapi/statehood has issues with certain cookie formats
  // We'll build the cookie string carefully to avoid parsing issues
  const parts: string[] = [`${name}=${value}`];
  
  if (maxAge) parts.push(`Max-Age=${maxAge}`);
  if (path) parts.push(`Path=${path}`);
  if (httpOnly) parts.push('HttpOnly');
  if (secure) parts.push('Secure');
  if (sameSite) parts.push(`SameSite=${sameSite}`);

  return parts.join('; ');
}
