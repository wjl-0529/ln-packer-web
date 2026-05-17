import 'dart:io';
import 'package:logger/logger.dart';

const String logFilePath = "ln_packer_web.log";

final File loggerFile = File(logFilePath);

Logger logger = Logger(
  printer: PrettyPrinter(
    colors: false,
    methodCount: 1,
    dateTimeFormat: DateTimeFormat.dateAndTime,
    printEmojis: false,
  ),
  output: FileOutput(
    file: loggerFile,
    overrideExisting: true,
  ),
  filter: ProductionFilter(),
);
