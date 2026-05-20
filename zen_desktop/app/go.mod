module zen_desktop

go 1.26.1

require (
	zenservice v0.0.0
)

require golang.org/x/text v0.34.0 // indirect

replace zenservice => ../core/go
