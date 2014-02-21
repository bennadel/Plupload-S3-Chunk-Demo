<cfscript>
	
	// Include the Amazon Web Service (AWS) S3 credentials.
	include "aws-credentials.cfm";

	// Include some utility methods to make the AWS interactions easier.
	include "udf.cfm";

	// The expiration must defined in UCT time. Since the Plupload widget may be on the
	// screen for a good amount of time, especially if this is a single-page app, we
	// probably need to put the expiration date into the future a good amount.
	expiration = dateConvert( "local2utc", dateAdd( "d", 1, now() ) );

	// NOTE: When formatting the UTC time, the hours must be in 24-hour time; therefore,
	// make sure to use "HH", not "hh" so that your policy don't expire prematurely.
	// ---
	// NOTE: We are providing a success_action_status INSTEAD of a success_action_redirect
	// since we don't want the browser to try and redirect (won't be supported across all
	// Plupload environments). Instead, we'll get Amazon S3 to return the XML document 
	// for the successful upload. Then, we can parse the response locally.
	policy = {
		"expiration" = (
			dateFormat( expiration, "yyyy-mm-dd" ) & "T" &
			timeFormat( expiration, "HH:mm:ss" ) & "Z"
		),
		"conditions" = [ 
			{
				"bucket" = aws.bucket
			}, 
			{
				"acl" = "private"
			},
			{
				"success_action_status" = "2xx"
			},
			[ "starts-with", "$key", "pluploads/" ],
			[ "starts-with", "$Content-Type", "image/" ],
			[ "content-length-range", 0, 10485760 ], // 10mb

			// The following keys are ones that Plupload will inject into the form-post 
			// across the various environments.
			// --
			// NOTE: If we do NOT chunk the file, we have to manually inject the "chunk"
			// and "chunks" keys in order to conform to the policy.
			[ "starts-with", "$Filename", "pluploads/" ],
			[ "starts-with", "$name", "" ],
			[ "starts-with", "$chunk", "" ],
			[ "starts-with", "$chunks", "" ]
		]
	};


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// The policy will be posted along with the FORM post as a hidden form field. 
	// Serialize it as JavaScript Object notation.
	serializedPolicy = serializeJson( policy );

	// When the policy is being serialized, ColdFusion will try to turn "201" into the 
	// number 201. However, we NEED this value to be a STRING. As such, we'll give the 
	// policy a non-numeric value and then convert it to the appropriate 201 after 
	// serialization.
	serializedPolicy = replace( serializedPolicy, "2xx", "201" );

	// Remove up the line breaks.
	serializedPolicy = reReplace( serializedPolicy, "[\r\n]+", "", "all" );

	// Encode the policy as Base64 so that it doesn't mess up the form post data at all.
	encodedPolicy = binaryEncode(
		charsetDecode( serializedPolicy, "utf-8" ) ,
		"base64"
	);


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// To make sure that no one tampers with the FORM POST, create hashed message 
	// authentication code of the policy content.
	encodedSignature = hmacSha1( encodedPolicy, aws.secretKey, "base64" );

</cfscript>

<!--- Reset the output buffer. --->
<cfcontent type="text/html; charset=utf-8" />

<!doctype html>
<html>
<head>
	<meta charset="utf-8" />

	<title>
		Chunking Amazon S3 File Uploads With Plupload And ColdFusion
	</title>

	<link rel="stylesheet" type="text/css" href="./assets/css/styles.css"></link>
</head>
<body>

	<h1>
		Chunking Amazon S3 File Uploads With Plupload And ColdFusion
	</h1>

	<div id="uploader" class="uploader">

		<a id="selectFiles" href="##">

			<span class="label">
				Select Files
			</span>

			<span class="standby">
				Waiting for files...
			</span>

			<span class="progress">
				Uploading - <span class="percent"></span>%
			</span>

		</a>

	</div>

	<div class="uploads">
		<!-- To be populated with uploads via JavaScript. -->
	</div>


	<!-- Load and initialize scripts. -->
	<script type="text/javascript" src="./assets/jquery/jquery-2.1.0.min.js"></script>
	<script type="text/javascript" src="./assets/plupload/js/plupload.full.min.js"></script>
	<script type="text/javascript">

		(function( $, plupload ) {

			// Find and cache the DOM elements we'll be using.
			var dom = {
				uploader: $( "#uploader" ),
				percent: $( "#uploader span.percent" ),
				uploads: $( "div.uploads" )
			};


			// Instantiate the Plupload uploader. When we do this, we have to pass in
			// all of the data that the Amazon S3 policy is going to be expecting. 
			// Also, we have to pass in the policy :)
			var uploader = new plupload.Uploader({

				// Try to load the HTML5 engine and then, if that's not supported, the 
				// Flash fallback engine.
				// --
				// NOTE: For Flash to work, you will have to upload the crossdomain.xml 
				// file to the root of your Amazon S3 bucket. Furthermore, chunking is 
				// sort of available in Flash, but its not that great.
				runtimes: "html5,flash",

				// The upload URL - our Amazon S3 bucket.
				url: <cfoutput>"http://#aws.bucket#.s3.amazonaws.com/"</cfoutput>,

				// The ID of the drop-zone element.
				drop_element: "uploader",

				// For the Flash engine, we have to define the ID of the node into which
				// Pluploader will inject the <OBJECT> tag for the flash movie.
				container: "uploader",

				// To enable click-to-select-files, you can provide a browse button. We
				// can use the same one as the drop zone.
				browse_button: "selectFiles",

				// The URL for the SWF file for the Flash upload engine for browsers that
				// don't support HTML5.
				flash_swf_url: "./assets/plupload/js/Moxie.swf",

				// Needed for the Flash environment to work.
				urlstream_upload: true,

				// NOTE: Unique names doesn't work with Amazon S3 and Plupload - see the
				// BeforeUpload event to see how we can generate unique file names.
				// --
				// unique_names: true,

				// The name of the form-field that will hold the upload data. Amason S3 
				// will expect this form field to be called, "file".
				file_data_name: "file",

				// This defines the maximum size that each file chunk can be. However, 
				// since Amazon S3 cannot handle multipart uploads smaller than 5MB, we'll
				// actually defer the setting of this value to the BeforeUpload at which 
				// point we'll have more information.
				// --
				// chunk_size: "5mb", // 5242880 bytes.

				// If the upload of a chunk fails, this is the number of times the chunk
				// should be re-uploaded before the upload (overall) is considered a 
				// failure.
				max_retries: 3,

				// Send any additional params (ie, multipart_params) in multipart message
				// format.
				multipart: true,

				// Pass through all the values needed by the Policy and the authentication
				// of the request.
				// --
				// NOTE: We are using the special value, ${filename} in our param 
				// definitions; but, we are actually overriding these in the BeforeUpload 
				// event. This notation is used when you do NOT know the name of the file 
				// that is about to be uploaded (and therefore cannot define it explicitly).
				multipart_params: {
					"acl": "private",
					"success_action_status": "201",
					"key": "pluploads/${filename}",
					"Filename": "pluploads/${filename}",
					"Content-Type": "image/*",
					"AWSAccessKeyId" : <cfoutput>"#aws.accessID#"</cfoutput>,
					"policy": <cfoutput>"#encodedPolicy#"</cfoutput>,
					"signature": <cfoutput>"#encodedSignature#"</cfoutput>
				}

			});

			// Set up the event handlers for the uploader.
			uploader.bind( "Init", handlePluploadInit );
			uploader.bind( "Error", handlePluploadError );
			uploader.bind( "FilesAdded", handlePluploadFilesAdded );
			uploader.bind( "QueueChanged", handlePluploadQueueChanged );
			uploader.bind( "BeforeUpload", handlePluploadBeforeUpload );
			uploader.bind( "UploadProgress", handlePluploadUploadProgress );
			uploader.bind( "ChunkUploaded", handlePluploadChunkUploaded );
			uploader.bind( "FileUploaded", handlePluploadFileUploaded );
			uploader.bind( "StateChanged", handlePluploadStateChanged );
			
			// Initialize the uploader (it is only after the initialization is complete that 
			// we will know which runtime load: html5 vs. Flash).
			uploader.init();


			// ------------------------------------------ //
			// ------------------------------------------ //


			// I handle the before upload event where the settings and the meta data can 
			// be edited right before the upload of a specific file, allowing for per-
			// file settings. In this case, this allows us to determine if given file 
			// needs to br (or can be) chunk-uploaded up to Amazon S3.
			function handlePluploadBeforeUpload( uploader, file ) {

				console.log( "File upload about to start.", file.name );

				// Track the chunking status of the file (for the success handler). With
				// Amazon S3, we can only chunk files if the leading chunks are at least
				// 5MB in size.
				file.isChunked = isFileSizeChunkableOnS3( file.size );

				// Generate the "unique" key for the Amazon S3 bucket based on the 
				// non-colliding Plupload ID. If we need to chunk this file, we'll create
				// an additional key below. Note that this is the file we want to create
				// eventually, NOT the chunk keys.
				file.s3Key = ( "pluploads/" + file.id + "/" + file.name );

				// This file can be chunked on S3 - at least 5MB in size.
				if ( file.isChunked ) {

					// Since this file is going to be chunked, we'll need to update the 
					// chunk index every time a chunk is uploaded. We'll start it at zero
					// and then increment it on each successful chunk upload.
					file.chunkIndex = 0;

					// Create the chunk-based S3 resource by appending the chunk index.
					file.chunkKey = ( file.s3Key + "." + file.chunkIndex );

					// Define the chunk size - this is what tells Plupload that the file
					// should be chunked. In this case, we are using 5MB because anything
					// smaller will be rejected by S3 later when we try to combine them.
					// --
					// NOTE: Once the Plupload settings are defined, we can't just use the
					// specialized size values - we actually have to pass in the parsed 
					// value (which is just the byte-size of the chunk).
					uploader.settings.chunk_size = plupload.parseSize( "5mb" );

					// Update the Key and Filename so that Amazon S3 will store the 
					// CHUNK resource at the correct location.
					uploader.settings.multipart_params.key = file.chunkKey;
					uploader.settings.multipart_params.Filename = file.chunkKey;

				// This file CANNOT be chunked on S3 - it's not large enough for S3's 
				// multi-upload resource constraints
				} else {

					// Remove the chunk size from the settings - this is what tells
					// Plupload that this file should NOT be chunked (ie, that it should
					// be uploaded as a single POST).
					uploader.settings.chunk_size = 0;

					// That said, in order to keep with the generated S3 policy, we still 
					// need to have the chunk "keys" in the POST. As such, we'll append 
					// them as additional multi-part parameters.
					uploader.settings.multipart_params.chunks = 0;
					uploader.settings.multipart_params.chunk = 0;

					// Update the Key and Filename so that Amazon S3 will store the 
					// base resource at the correct location.
					uploader.settings.multipart_params.key = file.s3Key;
					uploader.settings.multipart_params.Filename = file.s3Key;

				}

			}

			
			// I handle the successful upload of one of the chunks (of a larger file).
			function handlePluploadChunkUploaded( uploader, file, info ) {
			
				console.log( "Chunk uploaded.", info.offset, "of", info.total, "bytes." );	

				// As the chunks are uploaded, we need to change the target location of
				// the next chunk on Amazon S3. As such, we'll pre-increment the chunk 
				// index and then update the storage keys.
				file.chunkKey = ( file.s3Key + "." + ++file.chunkIndex );

				// Update the Amazon S3 chunk keys. By changing them here, Plupload will
				// automatically pick up the changes and apply them to the next chunk that
				// it uploads.
				uploader.settings.multipart_params.key = file.chunkKey;
				uploader.settings.multipart_params.Filename = file.chunkKey;

			}


			// I handle any errors raised during uploads.
			function handlePluploadError() {
				
				console.warn( "Error during upload." );

			}


			// I handle the files-added event. This is different that the queue-
			// changed event. At this point, we have an opportunity to reject files 
			// from the queue.
			function handlePluploadFilesAdded( uploader, files ) {

				console.log( "Files selected." );

				// NOTE: The demo calls for images; however, I'm NOT regulating that in 
				// code - trying to keep things smaller.
				// --
				// Example: file.splice( 0, 1 ).

			}


			// I handle the successful upload of a whole file. Even if a file is chunked,
			// this handler will be called with the same response provided to the last
			// chunk success handler.
			function handlePluploadFileUploaded( uploader, file, response ) {
			
				console.log( "Entire file uploaded.", response );
				
				var img = $( "<img>" )
					.prependTo( dom.uploads )
				;

				// If the file was chunked, target the CHUNKED success file in order to
				// initiate the rebuilding of the master file on Amazon S3.
				if ( file.isChunked ) {

					img.prop( "src", "./success_chunked.cfm?baseKey=" + encodeURIComponent( file.s3Key ) + "&chunks=" + file.chunkIndex );

				} else {

					img.prop( "src", "./success_not_chunked.cfm?baseKey=" + encodeURIComponent( file.s3Key ) );

				}

			}


			// I handle the init event. At this point, we will know which runtime has loaded,
			// and whether or not drag-drop functionality is supported.
			function handlePluploadInit( uploader, params ) {

				console.log( "Initialization complete." );
				console.info( "Drag-drop supported:", !! uploader.features.dragdrop );

			}


			// I handle the queue changed event.
			function handlePluploadQueueChanged( uploader ) {

				console.log( "Files added to queue." );

				if ( uploader.files.length && isNotUploading() ){

					uploader.start();

				}

			}


			// I handle the change in state of the uploader.
			function handlePluploadStateChanged( uploader ) {

				if ( isUploading() ) {

					dom.uploader.addClass( "uploading" );

				} else {

					dom.uploader.removeClass( "uploading" );

				}

			}


			// I handle the upload progress event. This gives us the progress of the given 
			// file, NOT of the entire upload queue.
			function handlePluploadUploadProgress( uploader, file ) {

				console.info( "Upload progress:", file.percent );

				dom.percent.text( file.percent );

			}


			// I determine if the given file size (in bytes) is large enough to allow 
			// for chunking on Amazon S3 (which requires each chunk by the last to be a 
			// minimum of 5MB in size).
			function isFileSizeChunkableOnS3( fileSize ) {

				var KB = 1024;
				var MB = ( KB * 1024 );
				var minSize = ( MB * 5 );

				return( fileSize > minSize );

			}


			// I determine if the upload is currently inactive.
			function isNotUploading() {

				var currentState = uploader.state;

				return( currentState === plupload.STOPPED );

			}


			// I determine if the uploader is currently uploading a file (or if it is inactive).
			function isUploading() {

				var currentState = uploader.state;

				return( currentState === plupload.STARTED );

			}

		})( jQuery, plupload );

	</script>

</body>
</html>