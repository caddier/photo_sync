import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';


class AlbumInfo {
  final String albumName;
  final int photoCount;
  final int videoCount;

  AlbumInfo({
    required this.albumName,
    required this.photoCount,
    required this.videoCount,
  });
}

class MediaEnumerator {
  // Ask for permission first
  static Future<bool> requestPermission() async {
    final PermissionState result = await PhotoManager.requestPermissionExtend();

    return result.isAuth;
  }


  static Future <List<AssetEntity>> getMediaEntities(RequestType type, AssetPathEntity album) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return [];
    }

    // Fetch media based on type
    List<AssetEntity> mediaEntities = await PhotoManager.getAssetListPaged(
      type: type,
      page: 0,
      pageCount: 100,
    );

    return mediaEntities;
  }


  static Future <List<AssetPathEntity>> getAlbumsByType(RequestType type) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return [];
    }

    // Fetch albums
    List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: type, 
      hasAll: true,
    );

    return albums;
  }


static Future<int> getMediaCountInAlbum(AssetPathEntity album) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return 0;
    }

    // Fetch count
    int count = await album.assetCountAsync;

    return count;
  }


static Future<Uint8List> getMediaData(AssetEntity asset) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return Uint8List(0);
    }
    Uint8List data = await asset.originBytes ?? Uint8List(0);
    return data;
  }

static Future<Uint8List> getThumbnailData(AssetEntity asset, {int width = 200, int height = 200}) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return Uint8List(0);
    }
    Uint8List? data = await asset.thumbnailDataWithSize(ThumbnailSize(width, height));
    return data ?? Uint8List(0);
  }


static Future<String> getMediaFileId(AssetEntity asset) async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return '';
    }
    String id = asset.id;
    return id;
  }


  // Get all albums with media counts
  static Future<List<AlbumInfo>> getAlbums() async {
    bool granted = await requestPermission();
    if (!granted) {
      PhotoManager.openSetting();
      return [];
    }

    // Fetch albums
    List<AssetPathEntity> photoAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.image, 
      hasAll: true,
    );

    List<AlbumInfo> result = [];

    var numPhotos = 0;
    var numVideos = 0;

    // Loop through albums
    for (var album in photoAlbums) {
      numPhotos = await album.assetCountAsync;
      AlbumInfo albumInfo = AlbumInfo(
        albumName: album.name,
        photoCount: numPhotos,
        videoCount: 0, // Placeholder, will update below
      );
      result.add(albumInfo);
    }

    // Fetch albums
    List<AssetPathEntity> videoAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.video, 
      hasAll: true,
    );

    for (var album in videoAlbums) {
      numVideos = await album.assetCountAsync;
      
      bool found = false;
      for (var i = 0 ; i < result.length; i++) {
        if (result[i].albumName == album.name) {
          result[i] = AlbumInfo(
            albumName: result[i].albumName,
            photoCount: result[i].photoCount,
            videoCount: numVideos,
          );
          found = true;
          break;
        }
      }
      if (found) continue;
      AlbumInfo albumInfo = AlbumInfo(
        albumName: album.name,
        photoCount: 0,
        videoCount: numVideos,
      );
      result.add(albumInfo);
    }

    return result;
  }



}
