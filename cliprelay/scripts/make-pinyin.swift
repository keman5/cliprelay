import Foundation
let preferred=[
    "ni":"你呢尼泥拟", "hao":"好号浩豪毫", "wo":"我握窝卧", "de":"的得德",
    "shi":"是时事市十", "zhong":"中种重众", "wen":"文问闻温", "jian":"见件间剪简",
    "tie":"贴铁帖", "ban":"板办班版", "tong":"同通统童", "bu":"不部步布",
    "ma":"吗妈马嘛", "lv":"绿吕旅律率", "nv":"女", "ren":"人认仁任", "you":"有又由友",
    "mei":"没每美妹", "zai":"在再", "shang":"上商尚", "xia":"下夏吓", "shui":"水谁睡",
    "he":"和喝合河", "le":"了乐", "jin":"今进近金", "tian":"天田甜", "qu":"去取区",
    "lai":"来", "niang":"娘酿", "men":"们门闷", "jie":"界接解节", "gua":"挂瓜"
]
var dictionary=preferred
for n in 0x4e00...0x9fff {
    let han=String(Unicode.Scalar(n)!)
    guard let latin = han.applyingTransform(.mandarinToLatin, reverse: false) else { continue }
    let pronunciation = latin.decomposedStringWithCanonicalMapping
        .replacingOccurrences(of: "u\u{308}", with: "v", options: .literal)
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
    guard pronunciation.range(of: "^[a-z]+$", options: .regularExpression) != nil else { continue }
    if dictionary[pronunciation]?.contains(han) != true {dictionary[pronunciation,default:""] += han}
}
precondition(dictionary["ni"]?.first == "你" && dictionary["nv"]?.contains("女") == true && dictionary["lv"]?.contains("綠") == true)
try JSONSerialization.data(withJSONObject:dictionary,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
