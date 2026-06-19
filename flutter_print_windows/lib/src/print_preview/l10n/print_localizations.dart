import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class PrintLocalizations {
  const PrintLocalizations._(this._strings);

  final _Strings _strings;

  static PrintLocalizations of(BuildContext context) =>
      Localizations.of<PrintLocalizations>(context, PrintLocalizations) ??
      const PrintLocalizations._(_en);

  static const LocalizationsDelegate<PrintLocalizations> delegate = _Delegate();

  static const supportedLocales = [
    Locale('en'),
    Locale('fr'),
    Locale('de'),
    Locale('es'),
    Locale('pt'),
    Locale('it'),
    Locale('nl'),
    Locale('ru'),
    Locale('pl'),
    Locale('tr'),
    Locale('ja'),
    Locale('zh'),
    Locale('ko'),
    Locale('ar'),
  ];

  String get title => _strings.title;
  String get cancel => _strings.cancel;
  String get print => _strings.print;
  String get printer => _strings.printer;
  String get noPrintersFound => _strings.noPrintersFound;
  String get copies => _strings.copies;
  String get layout => _strings.layout;
  String get portrait => _strings.portrait;
  String get landscape => _strings.landscape;
  String get color => _strings.color;
  String get colorMode => _strings.colorMode;
  String get grayscale => _strings.grayscale;
  String get paperSize => _strings.paperSize;
  String get twoSided => _strings.twoSided;
  String get off => _strings.off;
  String get longEdge => _strings.longEdge;
  String get shortEdge => _strings.shortEdge;
  String get previewUnavailable => _strings.previewUnavailable;
  String get noPreview => _strings.noPreview;

  String printerDisplayName(String name, {required bool isDefault}) => isDefault
      ? _strings.defaultPrinterFormat.replaceFirst('{name}', name)
      : name;
}

class _Delegate extends LocalizationsDelegate<PrintLocalizations> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => PrintLocalizations.supportedLocales.any(
    (l) => l.languageCode == locale.languageCode,
  );

  @override
  Future<PrintLocalizations> load(Locale locale) => SynchronousFuture(
    PrintLocalizations._(_stringsForLocale(locale.languageCode)),
  );

  @override
  bool shouldReload(_Delegate old) => false;
}

_Strings _stringsForLocale(String code) => switch (code) {
  'fr' => _fr,
  'de' => _de,
  'es' => _es,
  'pt' => _pt,
  'it' => _it,
  'nl' => _nl,
  'ru' => _ru,
  'pl' => _pl,
  'tr' => _tr,
  'ja' => _ja,
  'zh' => _zh,
  'ko' => _ko,
  'ar' => _ar,
  _ => _en,
};

class _Strings {
  const _Strings({
    required this.title,
    required this.cancel,
    required this.print,
    required this.printer,
    required this.noPrintersFound,
    required this.defaultPrinterFormat,
    required this.copies,
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
    required this.noPreview,
  });

  final String title;
  final String cancel;
  final String print;
  final String printer;
  final String noPrintersFound;
  final String defaultPrinterFormat;
  final String copies;
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
  final String noPreview;
}

// ---------------------------------------------------------------------------
// English
// ---------------------------------------------------------------------------

const _en = _Strings(
  title: 'Print',
  cancel: 'Cancel',
  print: 'Print',
  printer: 'Printer',
  noPrintersFound: 'No printers found',
  defaultPrinterFormat: '{name} (Default)',
  copies: 'Copies',
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
  noPreview: 'No preview for this file type',
);

// ---------------------------------------------------------------------------
// French
// ---------------------------------------------------------------------------

const _fr = _Strings(
  title: 'Imprimer',
  cancel: 'Annuler',
  print: 'Imprimer',
  printer: 'Imprimante',
  noPrintersFound: 'Aucune imprimante trouvée',
  defaultPrinterFormat: '{name} (Par défaut)',
  copies: 'Copies',
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
  noPreview: 'Aucun aperçu pour ce type de fichier',
);

// ---------------------------------------------------------------------------
// German
// ---------------------------------------------------------------------------

const _de = _Strings(
  title: 'Drucken',
  cancel: 'Abbrechen',
  print: 'Drucken',
  printer: 'Drucker',
  noPrintersFound: 'Keine Drucker gefunden',
  defaultPrinterFormat: '{name} (Standard)',
  copies: 'Kopien',
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
  noPreview: 'Keine Vorschau für diesen Dateityp',
);

// ---------------------------------------------------------------------------
// Spanish
// ---------------------------------------------------------------------------

const _es = _Strings(
  title: 'Imprimir',
  cancel: 'Cancelar',
  print: 'Imprimir',
  printer: 'Impresora',
  noPrintersFound: 'No se encontraron impresoras',
  defaultPrinterFormat: '{name} (Predeterminada)',
  copies: 'Copias',
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
  noPreview: 'Sin vista previa para este tipo de archivo',
);

// ---------------------------------------------------------------------------
// Portuguese
// ---------------------------------------------------------------------------

const _pt = _Strings(
  title: 'Imprimir',
  cancel: 'Cancelar',
  print: 'Imprimir',
  printer: 'Impressora',
  noPrintersFound: 'Nenhuma impressora encontrada',
  defaultPrinterFormat: '{name} (Padrão)',
  copies: 'Cópias',
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
  noPreview: 'Sem pré-visualização para este tipo de arquivo',
);

// ---------------------------------------------------------------------------
// Italian
// ---------------------------------------------------------------------------

const _it = _Strings(
  title: 'Stampa',
  cancel: 'Annulla',
  print: 'Stampa',
  printer: 'Stampante',
  noPrintersFound: 'Nessuna stampante trovata',
  defaultPrinterFormat: '{name} (Predefinita)',
  copies: 'Copie',
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
  noPreview: 'Nessuna anteprima per questo tipo di file',
);

// ---------------------------------------------------------------------------
// Dutch
// ---------------------------------------------------------------------------

const _nl = _Strings(
  title: 'Afdrukken',
  cancel: 'Annuleren',
  print: 'Afdrukken',
  printer: 'Printer',
  noPrintersFound: 'Geen printers gevonden',
  defaultPrinterFormat: '{name} (Standaard)',
  copies: 'Kopieën',
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
  noPreview: 'Geen voorbeeld voor dit bestandstype',
);

// ---------------------------------------------------------------------------
// Russian
// ---------------------------------------------------------------------------

const _ru = _Strings(
  title: 'Печать',
  cancel: 'Отмена',
  print: 'Печать',
  printer: 'Принтер',
  noPrintersFound: 'Принтеры не найдены',
  defaultPrinterFormat: '{name} (По умолчанию)',
  copies: 'Копии',
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
  noPreview: 'Нет предпросмотра для этого типа файла',
);

// ---------------------------------------------------------------------------
// Polish
// ---------------------------------------------------------------------------

const _pl = _Strings(
  title: 'Drukuj',
  cancel: 'Anuluj',
  print: 'Drukuj',
  printer: 'Drukarka',
  noPrintersFound: 'Nie znaleziono drukarek',
  defaultPrinterFormat: '{name} (Domyślna)',
  copies: 'Kopie',
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
  noPreview: 'Brak podglądu dla tego typu pliku',
);

// ---------------------------------------------------------------------------
// Turkish
// ---------------------------------------------------------------------------

const _tr = _Strings(
  title: 'Yazdır',
  cancel: 'İptal',
  print: 'Yazdır',
  printer: 'Yazıcı',
  noPrintersFound: 'Yazıcı bulunamadı',
  defaultPrinterFormat: '{name} (Varsayılan)',
  copies: 'Kopya',
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
  noPreview: 'Bu dosya türü için önizleme yok',
);

// ---------------------------------------------------------------------------
// Japanese
// ---------------------------------------------------------------------------

const _ja = _Strings(
  title: '印刷',
  cancel: 'キャンセル',
  print: '印刷',
  printer: 'プリンター',
  noPrintersFound: 'プリンターが見つかりません',
  defaultPrinterFormat: '{name}（既定）',
  copies: '部数',
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
  noPreview: 'このファイル形式はプレビューに対応していません',
);

// ---------------------------------------------------------------------------
// Chinese (Simplified)
// ---------------------------------------------------------------------------

const _zh = _Strings(
  title: '打印',
  cancel: '取消',
  print: '打印',
  printer: '打印机',
  noPrintersFound: '未找到打印机',
  defaultPrinterFormat: '{name}（默认）',
  copies: '份数',
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
  noPreview: '此文件类型没有预览',
);

// ---------------------------------------------------------------------------
// Korean
// ---------------------------------------------------------------------------

const _ko = _Strings(
  title: '인쇄',
  cancel: '취소',
  print: '인쇄',
  printer: '프린터',
  noPrintersFound: '프린터를 찾을 수 없습니다',
  defaultPrinterFormat: '{name} (기본값)',
  copies: '매수',
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
  noPreview: '이 파일 형식은 미리보기를 지원하지 않습니다',
);

// ---------------------------------------------------------------------------
// Arabic
// ---------------------------------------------------------------------------

const _ar = _Strings(
  title: 'طباعة',
  cancel: 'إلغاء',
  print: 'طباعة',
  printer: 'الطابعة',
  noPrintersFound: 'لا توجد طابعات',
  defaultPrinterFormat: '{name} (افتراضية)',
  copies: 'النسخ',
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
  noPreview: 'لا توجد معاينة لهذا النوع من الملفات',
);
