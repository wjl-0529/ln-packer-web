import 'package:ln_packer_web/light_novel/base/light_novel_model.dart';

Map<String, Object?> novelToJson(Novel novel) {
  return {
    "url": novel.url,
    "id": novel.id,
    "title": novel.title,
    "alias": novel.alias,
    "author": novel.author,
    "status": novel.status,
    "coverUrl": novel.coverUrl,
    "tags": novel.tags ?? const <String>[],
    "publisher": novel.publisher,
    "description": novel.description,
  };
}

Map<String, Object?> catalogToJson(Catalog catalog) {
  return {
    "volumes": [
      for (int i = 0; i < catalog.volumes.length; i++)
        volumeToJson(catalog.volumes[i], i),
    ],
  };
}

Map<String, Object?> volumeToJson(Volume volume, int index) {
  return {
    "index": index,
    "name": volume.volumeName.isEmpty
        ? volume.catalog.novel.title
        : volume.volumeName,
    "chapterCount": volume.chapters.length,
    "coverUrl": volume.cover,
    "chapters": [
      for (int i = 0; i < volume.chapters.length; i++)
        {
          "index": i,
          "name": volume.chapters[i].chapterName,
          "url": volume.chapters[i].chapterUrl,
        },
    ],
  };
}
