import Foundation

public enum TranslationError: Error, Equatable, Sendable {
    case notConfigured(String)
    case inputTooLong(max: Int)
    case network(String)
    case timeout
    case unauthorized
    case rateLimited
    case http(status: Int, message: String?)
    case invalidResponse
    case cancelled

    public var userMessage: String {
        switch self {
        case .notConfigured(let detail):
            return detail
        case .inputTooLong(let max):
            return "选中的文字过长（上限 \(max) 个字符），请缩短后再试。"
        case .network(let detail):
            return "网络连接失败：\(detail)"
        case .timeout:
            return "翻译服务响应超时，请稍后重试。"
        case .unauthorized:
            return "API Key 无效或没有权限，请在设置中检查个人 API 配置。"
        case .rateLimited:
            return "请求过于频繁或账户额度不足，请稍后再试。"
        case .http(let status, let message):
            if let message, !message.isEmpty { return "翻译服务返回错误（\(status)）：\(message)" }
            return "翻译服务返回错误（\(status)）。"
        case .invalidResponse:
            return "翻译服务返回了无法识别的结果，请重试。"
        case .cancelled:
            return "已取消。"
        }
    }
}
