//
//  AppDownload.swift
//  feather
//
//  Created by samara on 6/29/24.
//

import Foundation
import ZIPFoundation
import UIKit
import CoreData

class AppDownload: NSObject {
	let progress = Progress(totalUnitCount: 100)
	var dldelegate: DownloadDelegate?
	var downloads = [URLSessionDownloadTask: (uuid: String, appuuid: String, destinationUrl: URL, completion: (String?, String?, Error?) -> Void)]()
	var DirectoryUUID: String?
	var AppUUID: String?
	private var downloadTask: URLSessionDownloadTask?
	private var session: URLSession?

	func downloadFile(url: URL, appuuid: String, completion: @escaping (String?, String?, Error?) -> Void) {
		let uuid = UUID().uuidString
		self.DirectoryUUID = uuid
		self.AppUUID = appuuid
		guard let folderUrl = createUuidDirectory(uuid: uuid) else {
			completion(nil, nil, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create directory"]))
			return
		}

		let destinationUrl = folderUrl.appendingPathComponent(url.lastPathComponent)
		let sessionConfig = URLSessionConfiguration.default
		session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
		downloadTask = session?.downloadTask(with: url)

		downloads[downloadTask!] = (uuid: uuid, appuuid: appuuid, destinationUrl: destinationUrl, completion: completion)
		downloadTask!.resume()
	}

	func cancelDownload() {
		print("Cancelled?")
		downloadTask?.cancel()
		session?.invalidateAndCancel()
		downloadTask = nil
		session = nil
		progress.cancel()
	}

	func createUuidDirectory(uuid: String) -> URL? {
		let baseFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let folderUrl = baseFolder.appendingPathComponent("Apps/Unsigned").appendingPathComponent(uuid)

		do {
			try FileManager.default.createDirectory(at: folderUrl, withIntermediateDirectories: true, attributes: nil)
			return folderUrl
		} catch {
			return nil
		}
	}
	
	func extractCompressedBundle(packageURL: String, completion: @escaping (String?, Error?) -> Void) {
		let fileURL = URL(fileURLWithPath: packageURL)
		let destinationURL = fileURL.deletingLastPathComponent()
		let fileManager = FileManager.default

		if !fileManager.fileExists(atPath: fileURL.path) {
			completion(nil, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "File does not exist"]))
			return
		}

		// Define a progress object observer
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("Unzipping progress: \(progress.fractionCompleted)")
		}

		do {
			try fileManager.unzipItem(at: fileURL, to: destinationURL, progress: progress)
			
			if progress.isCancelled {
				if fileManager.fileExists(atPath: destinationURL.path) {
					try? fileManager.removeItem(at: destinationURL)
				}
				cancelDownload()
				completion(nil, NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unzip operation was cancelled"]))
				return
			}

			try fileManager.removeItem(at: fileURL)
			
			let payloadURL = destinationURL.appendingPathComponent("Payload")
			let contents = try fileManager.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil, options: [])
			
			if let appDirectory = contents.first(where: { $0.pathExtension == "app" }) {
				let sourceURL = appDirectory
				let targetURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
				try fileManager.moveItem(at: sourceURL, to: targetURL)
				try fileManager.removeItem(at: destinationURL.appendingPathComponent("Payload"))
				completion(targetURL.path, nil)
			} else {
				completion(nil, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No .app directory found in Payload"]))
			}
			
		} catch {
			if fileManager.fileExists(atPath: destinationURL.path) {
				try? fileManager.removeItem(at: destinationURL)
			}
			cancelDownload()
			completion(nil, error)
		}
	}



	func addToApps(bundlePath: String, uuid: String, completion: @escaping (Error?) -> Void) {
		guard let bundle = Bundle(path: bundlePath) else {
			let error = NSError(domain: "Feather", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load bundle at \(bundlePath)"])
			completion(error)
			return
		}

		if let infoDict = bundle.infoDictionary {

			var iconURL = ""
			if let iconsDict = infoDict["CFBundleIcons"] as? [String: Any],
			   let primaryIconsDict = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
			   let iconFiles = primaryIconsDict["CFBundleIconFiles"] as? [String],
			   let iconFileName = iconFiles.first,
			   let iconPath = bundle.path(forResource: iconFileName + "@2x", ofType: "png") {
				iconURL = "\(URL(string: iconPath)?.lastPathComponent ?? "")"
			}

			CoreDataManager.shared.addToDownloadedApps(
				version: (infoDict["CFBundleShortVersionString"] as? String)!,
				name: (infoDict["CFBundleDisplayName"] as? String ?? infoDict["CFBundleName"] as? String)!,
				bundleidentifier: (infoDict["CFBundleIdentifier"] as? String)!,
				iconURL: iconURL,
				uuid: uuid,
				appPath: "\(URL(string: bundlePath)?.lastPathComponent ?? "")") {_ in
			}

			completion(nil)
		} else {
			let error = NSError(domain: "Feather", code: 3, userInfo: [NSLocalizedDescriptionKey: "Info.plist not found in bundle at \(bundlePath)"])
			completion(error)
		}
	}
}

extension AppDownload: URLSessionDownloadDelegate {
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = downloads[downloadTask] else {
			return
		}
		let fileManager = FileManager.default
		do {
			try fileManager.moveItem(at: location, to: download.destinationUrl)
			download.completion(download.uuid, download.destinationUrl.path, nil)
		} catch {
			download.completion(download.uuid, download.destinationUrl.path, error)
		}
		downloads.removeValue(forKey: downloadTask)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let download = downloads[task as! URLSessionDownloadTask] else {
			return
		}
		if let error = error {
			download.completion(download.uuid, download.destinationUrl.path, error)
		}
		downloads.removeValue(forKey: task as! URLSessionDownloadTask)
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		let progress = CGFloat(totalBytesWritten) / CGFloat(totalBytesExpectedToWrite)
		if let uuid = downloads[downloadTask]?.appuuid {
			dldelegate?.updateDownloadProgress(progress: progress, uuid: uuid)
		}
	}
}