# Anime Shelf for iOS

تطبيق SwiftUI مخصص لـ iOS 26 يعرض قوائم الأنمي من خدمة Anime Slayer العامة، ويشغّل أفضل مصدر متاح مع تفضيل ملف 1080p، ويحفظ موضع المشاهدة محليًا بدقة أجزاء الثانية.

## المزايا

- الحلقات الجديدة، الأنميات المستمرة، المكتملة، والأكثر شهرة.
- قسم كبير «أكمل المشاهدة» مرتب حسب آخر مشاهدة.
- حفظ موضع كل حلقة بصيغة `HH:mm:ss.SSS` واستكمالها تلقائيًا.
- تشغيل 1080p من السيرفر البديل عند توفره، ثم الرجوع للمصدر الأساسي.
- عرض تعليقات Anime Cloud دون حساب أو Cookies أو Sessions.
- واجهة عربية وSwiftUI فقط.
- تصميم Liquid Glass أصلي من iOS 26 باستخدام `glassEffect` والأزرار الزجاجية التفاعلية.

## فتح المشروع على macOS

```bash
brew install xcodegen
xcodegen generate
open AnimeShelf.xcodeproj
```

اختر Apple Development Team من Signing & Capabilities ثم شغّل التطبيق على iPhone أو Simulator.

## ملف GitHub

Workflow باسم `Build iOS IPA` يبني نسخة iPhone غير موقعة وينشرها في GitHub Releases. يلزم توقيع ملف IPA بواسطة Apple ID من خلال AltStore أو Sideloadly قبل تثبيته على هاتف حقيقي.

## ملاحظة التعليقات

معرّفات حلقات Anime Slayer وAnime Cloud ليست نظامًا موحدًا. التطبيق يرسل معرّف الحلقة الحالي إلى خدمة التعليقات؛ إذا لم يوجد معرّف مقابل في Anime Cloud فستظهر القائمة فارغة بدل عرض تعليقات حلقة مختلفة.
