/**
 * Cloudflare Workers function to proxy webhook requests to n8n Cloud Run service
 * with retry logic for cold starts (404 errors)
 */

export default {
  async fetch(request, env) {
    // Get the target n8n Cloud Run URL from environment variables
    const targetUrl = env.N8N_URL;

    if (!targetUrl) {
      return new Response("N8N_URL environment variable not set", {
        status: 500,
        headers: { "Content-Type": "text/plain" },
      });
    }

    // Construct the target URL by replacing the workers domain with the Cloud Run domain
    const url = new URL(request.url);
    const targetRequestUrl = `${targetUrl}${url.pathname}${url.search}`;

    // Retry up to 60 seconds (5s intervals)
    const maxRetries = 12;
    const retryDelay = 5000;

    for (let attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        // Clone the request for each attempt (requests can only be used once)
        const requestClone = request.clone();

        // Create the proxied request
        const proxyRequest = new Request(targetRequestUrl, {
          method: requestClone.method,
          headers: requestClone.headers,
          body: requestClone.body,
          redirect: "follow",
        });

        // Make the request to the Cloud Run service
        const response = await fetch(proxyRequest);

        // If we get a 404, it might be a cold start - retry
        if (response.status === 404 && attempt < maxRetries) {
          console.log(
            `Attempt ${attempt + 1} failed with 404, retrying in ${
              retryDelay / 1000
            }s...`
          );
          await sleep(retryDelay);
          continue;
        }

        // For any other status code, return the response immediately
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers,
        });
      } catch (error) {
        // If this is the last attempt, return the error
        if (attempt === maxRetries) {
          const errorMessage = error instanceof Error ? error.message : "Unknown error";
          return new Response(
            `Failed to reach n8n service after ${
              maxRetries + 1
            } attempts: ${errorMessage}`,
            {
              status: 502,
              headers: { "Content-Type": "text/plain" },
            }
          );
        }

        // Otherwise, log and retry
        const errorMessage = error instanceof Error ? error.message : "Unknown error";
        console.log(
          `Attempt ${attempt + 1} failed with error: ${errorMessage}, retrying in ${
            retryDelay / 1000
          }s...`
        );
        await sleep(retryDelay);
      }
    }

    // This should never be reached, but just in case
    return new Response("Maximum retries exceeded", {
      status: 502,
      headers: { "Content-Type": "text/plain" },
    });
  },
};

// Helper function to sleep for a specified duration
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
