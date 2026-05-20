package core

type KLine struct {
	Date     int     `json:"Date"`
	YClose   float64 `json:"YClose"`
	Open     float64 `json:"Open"`
	Close    float64 `json:"Close"`
	High     float64 `json:"High"`
	Low      float64 `json:"Low"`
	Vol      float64 `json:"Vol"`
	Time     int     `json:"Time,omitempty"`
	Price    float64 `json:"Price,omitempty"`
	Turnover float64 `json:"Turnover,omitempty"`
	Amount   float64 `json:"Amount,omitempty"`
	AvPrice  float64 `json:"AvPrice,omitempty"`
}

type R struct {
	Symbol      string  `json:"Symbol"`
	Name        string  `json:"Name,omitempty"`
	Data        []KLine `json:"Data"`
	FlowCapital int     `json:"FlowCapital,omitempty"`
}

type APIOptions struct {
	MachineCode         func() string
	LicenseKey          func() (string, error)
	SaveLicense         func(string) error
	LicensePath         string
	EnableLicenseAPI    bool
	WatchListPath       string
	LicenseContent      string
	LicenseAcceptedPath string
	DebugMode           bool
	AuthToken           string
	AllowedOrigin       string
}
