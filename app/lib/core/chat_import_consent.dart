const contactChatNoticeVersion = '2026-11';

enum ChatImportConsent {
  reply('reply_chat_import', '2026-11-reply'),
  contact('chat_import', contactChatNoticeVersion);

  const ChatImportConsent(this.purpose, this.version);
  final String purpose;
  final String version;
}
