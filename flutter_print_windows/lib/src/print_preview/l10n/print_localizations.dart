import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class PrintLocalizations {
  const PrintLocalizations._({
    required this.title,
    required this.cancel,
    required this.print,
    required this.printer,
    required this.noPrintersFound,
    required this.defaultPrinterFormat,
    required this.copies,
    required this.pages,
    required this.allPages,
    required this.pageRangeCustom,
    required this.layout,
    required this.portrait,
    required this.landscape,
    required this.color,
    required this.colorMode,
    required this.grayscale,
    required this.paperSize,
    required this.twoSided,
    required this.off,
    required this.longEdge,
    required this.shortEdge,
    required this.previewUnavailable,
  });

  static PrintLocalizations of(BuildContext context) =>
      Localizations.of<PrintLocalizations>(context, PrintLocalizations) ?? _en;

  static const LocalizationsDelegate<PrintLocalizations> delegate = _Delegate();

  final String title;
  final String cancel;
  final String print;
  final String printer;
  final String noPrintersFound;
  final String defaultPrinterFormat;
  final String copies;
  final String pages;
  final String allPages;
  final String pageRangeCustom;
  final String layout;
  final String portrait;
  final String landscape;
  final String color;
  final String colorMode;
  final String grayscale;
  final String paperSize;
  final String twoSided;
  final String off;
  final String longEdge;
  final String shortEdge;
  final String previewUnavailable;

  String printerDisplayName(String name, {required bool isDefault}) =>
      isDefault ? defaultPrinterFormat.replaceFirst('{name}', name) : name;
}

class _Delegate extends LocalizationsDelegate<PrintLocalizations> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) =>
      _byLanguage.containsKey(locale.languageCode);

  @override
  Future<PrintLocalizations> load(Locale locale) =>
      SynchronousFuture(_byLanguage[locale.languageCode] ?? _en);

  @override
  bool shouldReload(_Delegate old) => false;
}

const _byLanguage = {
  'en': _en,
  'fr': _fr,
  'de': _de,
  'es': _es,
  'pt': _pt,
  'it': _it,
  'nl': _nl,
  'ru': _ru,
  'pl': _pl,
  'tr': _tr,
  'ja': _ja,
  'zh': _zh,
  'ko': _ko,
  'ar': _ar,
};

// ---------------------------------------------------------------------------
// English
// ---------------------------------------------------------------------------

const _en = PrintLocalizations._(
  title: 'Print',
  cancel: 'Cancel',
  print: 'Print',
  printer: 'Printer',
  noPrintersFound: 'No printers found',
  defaultPrinterFormat: '{name} (Default)',
  copies: 'Copies',
  pages: 'Pages',
  allPages: 'All',
  pageRangeCustom: 'Custom',
  layout: 'Layout',
  portrait: 'Portrait',
  landscape: 'Landscape',
  color: 'Color',
  colorMode: 'Color',
  grayscale: 'Grayscale',
  paperSize: 'Paper size',
  twoSided: 'Two-sided',
  off: 'Off',
  longEdge: 'Long edge',
  shortEdge: 'Short edge',
  previewUnavailable: 'Preview unavailable',
);

// ---------------------------------------------------------------------------
// French
// ---------------------------------------------------------------------------

const _fr = PrintLocalizations._(
  title: 'Imprimer',
  cancel: 'Annuler',
  print: 'Imprimer',
  printer: 'Imprimante',
  noPrintersFound: 'Aucune imprimante trouvée',
  defaultPrinterFormat: '{name} (Par défaut)',
  copies: 'Copies',
  pages: 'Pages',
  allPages: 'Toutes',
  pageRangeCustom: 'Personnalisé',
  layout: 'Mise en page',
  portrait: 'Portrait',
  landscape: 'Paysage',
  color: 'Couleur',
  colorMode: 'Couleur',
  grayscale: 'Nuances de gris',
  paperSize: 'Format du papier',
  twoSided: 'Recto-verso',
  off: 'Désactivé',
  longEdge: 'Bord long',
  shortEdge: 'Bord court',
  previewUnavailable: 'Aperçu non disponible',
);

// ---------------------------------------------------------------------------
// German
// ---------------------------------------------------------------------------

const _de = PrintLocalizations._(
  title: 'Drucken',
  cancel: 'Abbrechen',
  print: 'Drucken',
  printer: 'Drucker',
  noPrintersFound: 'Keine Drucker gefunden',
  defaultPrinterFormat: '{name} (Standard)',
  copies: 'Kopien',
  pages: 'Seiten',
  allPages: 'Alle',
  pageRangeCustom: 'Benutzerdefiniert',
  layout: 'Layout',
  portrait: 'Hochformat',
  landscape: 'Querformat',
  color: 'Farbe',
  colorMode: 'Farbe',
  grayscale: 'Graustufen',
  paperSize: 'Papiergröße',
  twoSided: 'Beidseitig',
  off: 'Aus',
  longEdge: 'Lange Kante',
  shortEdge: 'Kurze Kante',
  previewUnavailable: 'Vorschau nicht verfügbar',
);

// ---------------------------------------------------------------------------
// Spanish
// ---------------------------------------------------------------------------

const _es = PrintLocalizations._(
  title: 'Imprimir',
  cancel: 'Cancelar',
  print: 'Imprimir',
  printer: 'Impresora',
  noPrintersFound: 'No se encontraron impresoras',
  defaultPrinterFormat: '{name} (Predeterminada)',
  copies: 'Copias',
  pages: 'Páginas',
  allPages: 'Todas',
  pageRangeCustom: 'Personalizado',
  layout: 'Diseño',
  portrait: 'Vertical',
  landscape: 'Horizontal',
  color: 'Color',
  colorMode: 'Color',
  grayscale: 'Escala de grises',
  paperSize: 'Tamaño de papel',
  twoSided: 'Doble cara',
  off: 'Desactivado',
  longEdge: 'Borde largo',
  shortEdge: 'Borde corto',
  previewUnavailable: 'Vista previa no disponible',
);

// ---------------------------------------------------------------------------
// Portuguese
// ---------------------------------------------------------------------------

const _pt = PrintLocalizations._(
  title: 'Imprimir',
  cancel: 'Cancelar',
  print: 'Imprimir',
  printer: 'Impressora',
  noPrintersFound: 'Nenhuma impressora encontrada',
  defaultPrinterFormat: '{name} (Padrão)',
  copies: 'Cópias',
  pages: 'Páginas',
  allPages: 'Todas',
  pageRangeCustom: 'Personalizado',
  layout: 'Layout',
  portrait: 'Retrato',
  landscape: 'Paisagem',
  color: 'Cor',
  colorMode: 'Cor',
  grayscale: 'Escala de cinza',
  paperSize: 'Tamanho do papel',
  twoSided: 'Frente e verso',
  off: 'Desativado',
  longEdge: 'Borda longa',
  shortEdge: 'Borda curta',
  previewUnavailable: 'Pré-visualização indisponível',
);

// ---------------------------------------------------------------------------
// Italian
// ---------------------------------------------------------------------------

const _it = PrintLocalizations._(
  title: 'Stampa',
  cancel: 'Annulla',
  print: 'Stampa',
  printer: 'Stampante',
  noPrintersFound: 'Nessuna stampante trovata',
  defaultPrinterFormat: '{name} (Predefinita)',
  copies: 'Copie',
  pages: 'Pagine',
  allPages: 'Tutte',
  pageRangeCustom: 'Personalizzato',
  layout: 'Layout',
  portrait: 'Verticale',
  landscape: 'Orizzontale',
  color: 'Colore',
  colorMode: 'Colore',
  grayscale: 'Scala di grigi',
  paperSize: 'Formato carta',
  twoSided: 'Fronte-retro',
  off: 'Disattivato',
  longEdge: 'Bordo lungo',
  shortEdge: 'Bordo corto',
  previewUnavailable: 'Anteprima non disponibile',
);

// ---------------------------------------------------------------------------
// Dutch
// ---------------------------------------------------------------------------

const _nl = PrintLocalizations._(
  title: 'Afdrukken',
  cancel: 'Annuleren',
  print: 'Afdrukken',
  printer: 'Printer',
  noPrintersFound: 'Geen printers gevonden',
  defaultPrinterFormat: '{name} (Standaard)',
  copies: 'Kopieën',
  pages: 'Pagina\'s',
  allPages: 'Alle',
  pageRangeCustom: 'Aangepast',
  layout: 'Indeling',
  portrait: 'Staand',
  landscape: 'Liggend',
  color: 'Kleur',
  colorMode: 'Kleur',
  grayscale: 'Grijswaarden',
  paperSize: 'Papierformaat',
  twoSided: 'Dubbelzijdig',
  off: 'Uit',
  longEdge: 'Lange zijde',
  shortEdge: 'Korte zijde',
  previewUnavailable: 'Voorbeeld niet beschikbaar',
);

// ---------------------------------------------------------------------------
// Russian
// ---------------------------------------------------------------------------

const _ru = PrintLocalizations._(
  title: 'Печать',
  cancel: 'Отмена',
  print: 'Печать',
  printer: 'Принтер',
  noPrintersFound: 'Принтеры не найдены',
  defaultPrinterFormat: '{name} (По умолчанию)',
  copies: 'Копии',
  pages: 'Страницы',
  allPages: 'Все',
  pageRangeCustom: 'Выборочно',
  layout: 'Ориентация',
  portrait: 'Книжная',
  landscape: 'Альбомная',
  color: 'Цвет',
  colorMode: 'Цветная',
  grayscale: 'Оттенки серого',
  paperSize: 'Размер бумаги',
  twoSided: 'Двусторонняя',
  off: 'Выкл',
  longEdge: 'Длинная сторона',
  shortEdge: 'Короткая сторона',
  previewUnavailable: 'Предпросмотр недоступен',
);

// ---------------------------------------------------------------------------
// Polish
// ---------------------------------------------------------------------------

const _pl = PrintLocalizations._(
  title: 'Drukuj',
  cancel: 'Anuluj',
  print: 'Drukuj',
  printer: 'Drukarka',
  noPrintersFound: 'Nie znaleziono drukarek',
  defaultPrinterFormat: '{name} (Domyślna)',
  copies: 'Kopie',
  pages: 'Strony',
  allPages: 'Wszystkie',
  pageRangeCustom: 'Niestandardowy',
  layout: 'Układ',
  portrait: 'Pionowy',
  landscape: 'Poziomy',
  color: 'Kolor',
  colorMode: 'Kolor',
  grayscale: 'Skala szarości',
  paperSize: 'Rozmiar papieru',
  twoSided: 'Dwustronne',
  off: 'Wył.',
  longEdge: 'Długa krawędź',
  shortEdge: 'Krótka krawędź',
  previewUnavailable: 'Podgląd niedostępny',
);

// ---------------------------------------------------------------------------
// Turkish
// ---------------------------------------------------------------------------

const _tr = PrintLocalizations._(
  title: 'Yazdır',
  cancel: 'İptal',
  print: 'Yazdır',
  printer: 'Yazıcı',
  noPrintersFound: 'Yazıcı bulunamadı',
  defaultPrinterFormat: '{name} (Varsayılan)',
  copies: 'Kopya',
  pages: 'Sayfalar',
  allPages: 'Tümü',
  pageRangeCustom: 'Özel',
  layout: 'Yön',
  portrait: 'Dikey',
  landscape: 'Yatay',
  color: 'Renk',
  colorMode: 'Renkli',
  grayscale: 'Gri tonlamalı',
  paperSize: 'Kağıt boyutu',
  twoSided: 'Çift taraflı',
  off: 'Kapalı',
  longEdge: 'Uzun kenar',
  shortEdge: 'Kısa kenar',
  previewUnavailable: 'Önizleme kullanılamıyor',
);

// ---------------------------------------------------------------------------
// Japanese
// ---------------------------------------------------------------------------

const _ja = PrintLocalizations._(
  title: '印刷',
  cancel: 'キャンセル',
  print: '印刷',
  printer: 'プリンター',
  noPrintersFound: 'プリンターが見つかりません',
  defaultPrinterFormat: '{name}（既定）',
  copies: '部数',
  pages: 'ページ',
  allPages: 'すべて',
  pageRangeCustom: 'カスタム',
  layout: '印刷の向き',
  portrait: '縦',
  landscape: '横',
  color: 'カラー',
  colorMode: 'カラー',
  grayscale: 'グレースケール',
  paperSize: '用紙サイズ',
  twoSided: '両面印刷',
  off: 'なし',
  longEdge: '長辺とじ',
  shortEdge: '短辺とじ',
  previewUnavailable: 'プレビューを表示できません',
);

// ---------------------------------------------------------------------------
// Chinese (Simplified)
// ---------------------------------------------------------------------------

const _zh = PrintLocalizations._(
  title: '打印',
  cancel: '取消',
  print: '打印',
  printer: '打印机',
  noPrintersFound: '未找到打印机',
  defaultPrinterFormat: '{name}（默认）',
  copies: '份数',
  pages: '页面',
  allPages: '全部',
  pageRangeCustom: '自定义',
  layout: '方向',
  portrait: '纵向',
  landscape: '横向',
  color: '颜色',
  colorMode: '彩色',
  grayscale: '灰度',
  paperSize: '纸张大小',
  twoSided: '双面打印',
  off: '关闭',
  longEdge: '长边翻转',
  shortEdge: '短边翻转',
  previewUnavailable: '预览不可用',
);

// ---------------------------------------------------------------------------
// Korean
// ---------------------------------------------------------------------------

const _ko = PrintLocalizations._(
  title: '인쇄',
  cancel: '취소',
  print: '인쇄',
  printer: '프린터',
  noPrintersFound: '프린터를 찾을 수 없습니다',
  defaultPrinterFormat: '{name} (기본값)',
  copies: '매수',
  pages: '페이지',
  allPages: '모두',
  pageRangeCustom: '사용자 지정',
  layout: '방향',
  portrait: '세로',
  landscape: '가로',
  color: '색상',
  colorMode: '컬러',
  grayscale: '회색조',
  paperSize: '용지 크기',
  twoSided: '양면 인쇄',
  off: '끄기',
  longEdge: '긴 가장자리',
  shortEdge: '짧은 가장자리',
  previewUnavailable: '미리보기를 사용할 수 없습니다',
);

// ---------------------------------------------------------------------------
// Arabic
// ---------------------------------------------------------------------------

const _ar = PrintLocalizations._(
  title: 'طباعة',
  cancel: 'إلغاء',
  print: 'طباعة',
  printer: 'الطابعة',
  noPrintersFound: 'لا توجد طابعات',
  defaultPrinterFormat: '{name} (افتراضية)',
  copies: 'النسخ',
  pages: 'الصفحات',
  allPages: 'الكل',
  pageRangeCustom: 'مخصص',
  layout: 'الاتجاه',
  portrait: 'عمودي',
  landscape: 'أفقي',
  color: 'اللون',
  colorMode: 'ملون',
  grayscale: 'تدرج رمادي',
  paperSize: 'حجم الورق',
  twoSided: 'طباعة مزدوجة',
  off: 'إيقاف',
  longEdge: 'الحافة الطويلة',
  shortEdge: 'الحافة القصيرة',
  previewUnavailable: 'المعاينة غير متاحة',
);
