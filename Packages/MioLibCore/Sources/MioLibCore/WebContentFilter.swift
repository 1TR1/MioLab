import Foundation

// 内置小型规则集只针对明确的广告域名与广告容器，不用含糊的 ad 子串隐藏正文。
public enum WebContentFilter {
  public static let identifier = "MioLib.ads.v1"
  public static let domains = [
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
    "adnxs.com", "adsrvr.org", "amazon-adsystem.com", "criteo.com", "criteo.net",
    "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com",
    "cpro.baidu.com", "pos.baidu.com", "union.baidu.com", "mobads.baidu.com",
    "bdunion.com", "tanx.com", "gdt.qq.com", "ad.qq.com"
  ]
  public static let selectors = ".adsbygoogle, [id^='google_ads_iframe'], [id^='div-gpt-ad'], .ad-banner, .ad-container, .advertisement, [data-ad-slot]"

  // 锚定协议和完整主机边界，避免把正文 URL 的查询参数或相似域名误认为广告源。
  public static func pattern(for domain: String) -> String {
    "^https?://([a-z0-9-]+\\.)*" + domain.replacingOccurrences(of: ".", with: "\\.") + "[/:]"
  }

  // 规则在第一次网络请求前交由 WebKit 编译，资源阻断和隐藏空广告位同时生效。
  public static func rulesJSON() throws -> String {
    var rules: [[String: Any]] = domains.map { domain in
      ["trigger": ["url-filter": pattern(for: domain), "load-type": ["third-party"]],
       "action": ["type": "block"]]
    }
    rules.append(["trigger": ["url-filter": ".*"],
      "action": ["type": "css-display-none", "selector": selectors]])
    let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
