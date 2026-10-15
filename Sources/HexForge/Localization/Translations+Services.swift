extension L10n {
    /// User-visible strings produced by the Services layer and surfaced in the
    /// status bar, transform panel and error alerts.
    static let zhServices: [String: String] = [
        // CryptoTransform — operation descriptions
        "XORs every byte with a repeating key (hex or text).": "用循环密钥（十六进制或文本）对每个字节做 XOR。",
        "ANDs every byte with the constant.": "将每个字节与常量做 AND。",
        "ORs every byte with the constant.": "将每个字节与常量做 OR。",
        "Inverts every bit of every selected byte.": "反转每个已选字节的所有位。",
        "Adds the constant to every byte (mod 256).": "将常量加到每个字节（模 256）。",
        "Subtracts the constant from every byte (mod 256).": "从每个字节减去常量（模 256）。",
        "Reverses the byte order of the whole range.": "反转整个范围的字节顺序。",
        "Reverses the bytes inside each word (endianness swap).": "反转每个字内的字节（大小端交换）。",
        "Encodes the bytes as Base64 text (length grows).": "把字节编码为 Base64 文本（长度增加）。",
        "Decodes Base64 text back to bytes (length shrinks).": "把 Base64 文本解码回字节（长度减少）。",
        "Rotates ASCII letters by 13 positions.": "把 ASCII 字母循环移位 13 位。",
        "AES encrypt with PKCS#7 padding (ECB or CBC).": "AES 加密，使用 PKCS#7 填充（ECB 或 CBC）。",
        "AES decrypt; PKCS#7 padding is removed.": "AES 解密；移除 PKCS#7 填充。",
        "DES encrypt with PKCS#7 padding (ECB or CBC).": "DES 加密，使用 PKCS#7 填充（ECB 或 CBC）。",
        "DES decrypt; PKCS#7 padding is removed.": "DES 解密；移除 PKCS#7 填充。",

        // CryptoTransform — errors and outcome messages
        "Constant: %@": "常量：%@",
        "Input is not valid Base64.": "输入不是有效的 Base64。",
        "Cipher failed (status %d).": "加密运算失败（状态 %d）。",
        "XORed %d byte(s) with a %d-byte key": "已用 %d 字节密钥对 %d 字节做 XOR",
        "%@ applied to %d byte(s)": "已对 %d 字节应用 %@",
        "Inverted %d byte(s)": "已反转 %d 字节",
        "Reversed %d byte(s)": "已逆序 %d 字节",
        "Byte-swapped %d-byte words": "已交换 %d 字节字内的字节序",
        "Base64 encoded %d byte(s) → %d chars": "已把 %d 字节编码为 Base64 → %d 个字符",
        "Base64 decoded %d char(s) → %d byte(s)": "已把 %d 个 Base64 字符解码 → %d 字节",
        "ROT13 applied to %d byte(s)": "已对 %d 字节应用 ROT13",
        "%@-%@ %@ %d → %d byte(s)": "%@-%@ %@ %d → %d 字节",
        "%@ is empty": "%@ 为空",
        "%@ hex needs an even number of digits": "%@ 的十六进制需要偶数个字符",
        "%@ contains non-hex characters": "%@ 含有非十六进制字符",
        "encrypted": "加密",
        "decrypted": "解密",
        "must be a byte value (0x00–0xFF)": "必须是字节值（0x00–0xFF）",

        // FileComparer
        "%@ vs %@  ·  %d difference run(s)  ·  %@ / %@ bytes": "%@ 对比 %@  ·  %d 处差异  ·  %@ / %@ 字节",
        "Cannot read %@": "无法读取 %@",
        "Comparison cancelled.": "比较已取消。",

        // DiskCloner / DiskImager
        "Source and destination are the same.": "来源与目标相同。",
        "Cannot read source: %@": "无法读取来源：%@",
        "Cannot write destination: %@": "无法写入目标：%@",
        "Clone cancelled.": "克隆已取消。",
        "Verification failed at offset 0x%@.": "校验失败，位置 0x%@。",
        "Cannot write: %@": "无法写入：%@",
        "Imaging cancelled.": "映像创建已取消。",
        "Compression failed.": "压缩失败。",
        "Cannot read manifest: %@": "无法读取清单：%@",

        // FileTools
        "The requested size is not valid.": "请求的大小无效。",
        "The source is empty.": "源文件为空。",
        "No parts were supplied to join.": "未提供任何用于合并的分片。",
        "Operation cancelled.": "操作已取消。",
        "Could not obtain random bytes.": "无法获取随机字节。",

        // StructureTemplate
        "Cannot read template file: %@": "无法读取模板文件：%@",
        "Invalid template file: %@": "模板文件无效：%@",
        "expected a template object or an array of templates": "应为模板对象或模板数组",
        "no templates found": "未找到任何模板",
        "template \"%@\" has no \"fields\"": "模板 \"%@\" 缺少 \"fields\"",
        "template \"%@\": a field is missing \"name\"": "模板 \"%@\"：某个字段缺少 \"name\"",
        "field \"%@\": missing or invalid \"offset\"": "字段 \"%@\"：\"offset\" 缺失或无效",
        "field \"%@\": missing \"kind\"": "字段 \"%@\"：缺少 \"kind\"",
        "field \"%@\": unknown kind \"%@\"": "字段 \"%@\"：未知的 kind \"%@\""
    ]
}
