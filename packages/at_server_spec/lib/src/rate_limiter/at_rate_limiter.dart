/// A rate limiter class that allows controlling the rate of requests within a specified time frame.
///
/// This class provides a way to limit the number of requests that can be made
/// within a specified time frame. It keeps track of the timestamps of previous
/// requests and allows requests to be made only if they do not exceed the
/// maximum allowed requests per time frame.
abstract class AtRateLimiter {
  /// The maximum number of requests allowed within the specified time frame.
  late int maxRequestsPerTimeFrame;

  /// The duration of the time frame within which requests are limited.
  late int timeFrameInMillis;

  /// Checks whether a new request is allowed based on the rate limiting rules.
  ///
  /// Returns `true` if the request is allowed, or `false` if it exceeds the rate limit.
  bool isRequestAllowed();
}
